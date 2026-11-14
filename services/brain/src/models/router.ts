import { sha256Hex } from "@offload/contracts";
import { createNameMasker, type NameMasker } from "@offload/masking/src/names/index.ts";
import { ALLOWED_MODEL_IDS, NEVER_LOCAL_ROUTES, type ModelsConfig, type TierConfig } from "./config.ts";
import { nextTier } from "./escalation.ts";
import { assertLabelSchema, LabelSchemaError, validateLabelOutput } from "./labels.ts";
import { UNTRUSTED_SYSTEM_NOTE, untrustedTagsBalanced } from "./untrusted.ts";
import type {
  AttemptOutcome,
  AttemptRecord,
  AuditPort,
  BudgetLedger,
  Clock,
  JsonSchema,
  LeakScanner,
  LedgerScope,
  LogLine,
  ModelMessage,
  ModelProvider,
  ModelRequest,
  NeedsYouReason,
  PaidTier,
  RefusedReason,
  RouteResult,
  Tier,
} from "./types.ts";

/**
 * The model router (ADR 0021, ARCHITECTURE section 17): the one egress for product model calls.
 * Order on every call: untrusted-tag check, masking second pass (ADR 0005), leak scan, budget, send, escalation,
 * label validation. Masked text only reaches models; the per-run name map never leaves the masker.
 */

export interface RouteCall {
  /** Idempotency key for the ledger. Generated when absent. Attempt n > 1 is keyed `${call_id}:${n}`. */
  call_id?: string;
  tenant_id: string;
  member_id?: string;
  run_id?: string;
  route: string;
  system: string;
  messages: ModelMessage[];
  /** Label-only JSON Schema for structured output. */
  schema?: JsonSchema;
  max_tokens: number;
  own_name?: string;
  own_name_to_models?: "mask" | "keep";
  run_budget_usd?: number;
  scope?: LedgerScope;
  scope_id?: string;
}

export interface RouterDeps {
  provider: ModelProvider;
  ledger: BudgetLedger;
  scanner: LeakScanner;
  audit: AuditPort;
  clock: Clock;
  config: ModelsConfig;
  /** Masker per run (one tag and name map per run). Default: a new masker per call. */
  maskers?: RunMaskers;
  log?: (line: LogLine) => void;
}

/** Share at 80% of the monthly budget from which classify and caption move to the local tier. */
export const LOCAL_SHIFT_SHARE = 0.8;
export const LEAK_AUDIT_ACTION = "privacy.leak_blocked";
const ROUTER_PRINCIPAL = "brain.model_router";
const MTOK = 1_000_000;

/**
 * In-memory maskers for runs in flight. The name map lives only inside each masker; `end` drops it when the run ends.
 */
export class RunMaskers {
  private readonly runs = new Map<string, NameMasker>();
  constructor(private readonly maxRuns = 1000) {}

  /** One masker per run and own-name setting: a call with a different own name never reuses a masker without it. */
  forRun(run_id: string, opts: { ownName?: string; ownNameToModels?: "mask" | "keep" }): NameMasker {
    const key = JSON.stringify([run_id, opts.ownName ?? null, opts.ownNameToModels ?? "mask"]);
    let m = this.runs.get(key);
    if (!m) {
      if (this.runs.size >= this.maxRuns) this.runs.delete(this.runs.keys().next().value as string);
      m = createNameMasker(opts);
      this.runs.set(key, m);
    }
    return m;
  }

  end(run_id: string): void {
    for (const key of [...this.runs.keys()]) if ((JSON.parse(key) as unknown[])[0] === run_id) this.runs.delete(key);
  }
}

function monthStartUtc(d: Date): Date {
  return new Date(Date.UTC(d.getUTCFullYear(), d.getUTCMonth(), 1));
}

function priced(t: TierConfig): t is TierConfig & { usd_per_mtok_in: number; usd_per_mtok_out: number } {
  return t.usd_per_mtok_in !== null && t.usd_per_mtok_out !== null;
}

const CALL_ID_RE = /^[A-Za-z0-9_.-]{1,100}$/;
/** Upper bound for max_tokens on any tier (128K output). */
export const MAX_OUTPUT_TOKENS = 128_000;

function validCall(call: RouteCall): boolean {
  if (call.call_id !== undefined && !CALL_ID_RE.test(call.call_id)) return false;
  if (!Number.isInteger(call.max_tokens) || call.max_tokens < 1 || call.max_tokens > MAX_OUTPUT_TOKENS) return false;
  if (typeof call.system !== "string" || !Array.isArray(call.messages) || call.messages.length === 0) return false;
  if (!call.messages.every((m) => (m.role === "user" || m.role === "assistant") && typeof m.content === "string")) return false;
  if (call.run_budget_usd !== undefined && !(Number.isFinite(call.run_budget_usd) && call.run_budget_usd >= 0)) return false;
  return true;
}

/** Every property name and string value in a schema, for the name check. */
function schemaStrings(node: unknown, out: string[] = []): string[] {
  if (typeof node === "string") out.push(node);
  else if (Array.isArray(node)) for (const v of node) schemaStrings(v, out);
  else if (typeof node === "object" && node !== null) {
    for (const [k, v] of Object.entries(node)) {
      out.push(k);
      schemaStrings(v, out);
    }
  }
  return out;
}

function outcomeOf(stop_reason: string, content: string, schema: JsonSchema | undefined): { outcome: AttemptOutcome; output?: unknown } {
  if (stop_reason === "refusal") return { outcome: "refusal" };
  if (stop_reason === "max_tokens") return { outcome: "cut_off" };
  if (stop_reason !== "end_turn" && stop_reason !== "stop_sequence") return { outcome: "invalid_output" };
  if (schema === undefined) return { outcome: "ok" };
  let parsed: unknown;
  try {
    parsed = JSON.parse(content);
  } catch {
    return { outcome: "invalid_output" };
  }
  return validateLabelOutput(schema, parsed) ? { outcome: "ok", output: parsed } : { outcome: "invalid_output" };
}

export async function route(call: RouteCall, deps: RouterDeps): Promise<RouteResult> {
  const { config, ledger, provider, clock } = deps;
  const call_id = call.call_id ?? crypto.randomUUID();
  const attempts: AttemptRecord[] = [];
  const log = (status: string, reason: string | null, tier: Tier | null = null) =>
    deps.log?.({
      event: "model_call",
      call_id,
      route: call.route,
      tier,
      status,
      reason,
      attempts: attempts.length,
      usd: attempts.reduce((s, a) => s + a.usd, 0),
    });
  const refused = (reason: RefusedReason, detectors?: string[]): RouteResult => {
    log("refused", reason);
    return detectors ? { status: "refused", call_id, route: call.route, reason, detectors } : { status: "refused", call_id, route: call.route, reason };
  };
  const needsYou = (reason: NeedsYouReason, tier: Tier | null = null): RouteResult => {
    log("needs_you", reason, tier);
    return { status: "needs_you", call_id, route: call.route, reason, attempts };
  };

  if (!validCall(call)) return refused("invalid_call");

  // Route → tier.
  const paidTier: PaidTier | undefined = Object.hasOwn(config.routes, call.route) ? config.routes[call.route] : undefined;
  const localServes = config.local_routes.includes(call.route) && !NEVER_LOCAL_ROUTES.includes(call.route);
  if (!paidTier && !localServes) return refused("unknown_route");

  // Labels: a schema must be label-only before anything is sent.
  if (call.schema !== undefined) {
    try {
      assertLabelSchema(call.schema);
    } catch (e) {
      if (e instanceof LabelSchemaError) return refused("schema_not_label_only");
      throw e;
    }
  }

  // Masking options for this call (used for the schema check and the masking pass).
  const maskerOpts: { ownName?: string; ownNameToModels?: "mask" | "keep" } = {};
  if (call.own_name !== undefined) maskerOpts.ownName = call.own_name;
  if (call.own_name_to_models !== undefined) maskerOpts.ownNameToModels = call.own_name_to_models;

  // A schema is sent as written, so it must hold no person name: masking its labels would change what code maps.
  if (call.schema !== undefined) {
    const probe = createNameMasker({ ...maskerOpts, ownNameToModels: "mask" });
    if (schemaStrings(call.schema).some((str) => probe.mask(str) !== str)) return refused("schema_holds_name");
  }

  // 1. Untrusted wrapping: no tag may escape.
  if (!untrustedTagsBalanced(call.system) || !call.messages.every((m) => untrustedTagsBalanced(m.content))) {
    return refused("untrusted_tag_escape");
  }

  // 2. Masking second pass.
  const masker = call.run_id !== undefined && deps.maskers ? deps.maskers.forRun(call.run_id, maskerOpts) : createNameMasker(maskerOpts);
  const system = `${masker.mask(call.system)}\n\n${UNTRUSTED_SYSTEM_NOTE}`;
  const messages: ModelMessage[] = call.messages.map((m) => ({ role: m.role, content: masker.mask(m.content) }));

  // 3. Leak scan over the masked request.
  const requestText = JSON.stringify({ system, messages, schema: call.schema ?? null });
  const hits = [...new Set(deps.scanner.scan(requestText).map((h) => h.detector))];
  if (hits.length > 0) {
    const request_sha256 = sha256Hex(requestText);
    for (const detector of hits) {
      await deps.audit.append(call.tenant_id, {
        principalId: call.member_id ?? ROUTER_PRINCIPAL,
        action: LEAK_AUDIT_ACTION,
        subjectType: "model_call",
        subjectId: call_id,
        details: { call_id, route: call.route, detector, request_sha256 },
      });
    }
    return refused("leak_blocked", hits);
  }

  // 4. Budget: pick the starting tier.
  const now = clock.now();
  const monthStart = monthStartUtc(now);
  const budget = await ledger.monthlyBudgetUsd(call.tenant_id);
  const spentAtStart = await ledger.spentThisMonth(call.tenant_id, monthStart);
  let tier: Tier;
  if (!paidTier) {
    if (!config.local) return needsYou("local_tier_off");
    tier = "local";
  } else if (localServes && config.local && spentAtStart >= LOCAL_SHIFT_SHARE * budget) {
    tier = "local";
  } else {
    tier = paidTier;
  }

  for (let attempt = 1; ; attempt++) {
    // Allowlist and prices, before any reservation or send.
    let model: string;
    let prices: { in: number; out: number; cache: number };
    if (tier === "local") {
      model = config.local!.model;
      prices = { in: 0, out: 0, cache: 0 };
    } else {
      const t = config.tiers[tier];
      if (!config.allowlist.includes(t.id) || !ALLOWED_MODEL_IDS.includes(t.id)) return refused("model_not_allowed");
      if (!priced(t)) return needsYou("prices_not_configured", tier);
      prices = { in: t.usd_per_mtok_in, out: t.usd_per_mtok_out, cache: t.usd_per_mtok_cache_read ?? t.usd_per_mtok_in };
      model = t.id;
    }

    const req: ModelRequest = { call_id, attempt, tier, model, system, messages, max_tokens: call.max_tokens };
    if (call.schema !== undefined) req.schema = call.schema;

    // Worst-case reservation: estimated input × input price + max_tokens × output price.
    const reserveUsd = (provider.estimateInputTokens(req) * prices.in + call.max_tokens * prices.out) / MTOK;
    if (tier !== "local") {
      const cap = Object.hasOwn(config.max_usd_per_call, call.route) ? config.max_usd_per_call[call.route] : undefined;
      if (cap !== undefined && reserveUsd > cap) return needsYou("call_budget_exceeded", tier);
      if (call.run_budget_usd !== undefined) {
        const spentRun = call.run_id !== undefined ? await ledger.spentThisRun(call.run_id) : attempts.reduce((s, a) => s + a.usd, 0);
        if (spentRun + reserveUsd > call.run_budget_usd) return needsYou("run_budget_reached", tier);
      }
      const spentMonth = attempt === 1 ? spentAtStart : await ledger.spentThisMonth(call.tenant_id, monthStart);
      if (spentMonth >= budget || spentMonth + reserveUsd > budget) return needsYou("monthly_budget_reached", tier);
    }

    const reservation = await ledger.reserve({
      tenant_id: call.tenant_id,
      idempotency_key: attempt === 1 ? call_id : `${call_id}:${attempt}`,
      scope: call.scope ?? "brain",
      scope_id: call.scope_id ?? null,
      run_id: call.run_id ?? null,
      model,
      route: call.route,
      usd: reserveUsd,
      at: clock.now(),
      limits: { month_start: monthStart, monthly_budget_usd: budget, run_budget_usd: call.run_budget_usd ?? null },
    });
    if (reservation.state === "over_budget") return needsYou(reservation.limit === "run" ? "run_budget_reached" : "monthly_budget_reached", tier);
    if (reservation.state !== "new") return needsYou(reservation.state === "settled" ? "call_already_settled" : "call_in_flight", tier);

    // 5. Send. stop_reason is checked first (in the adapter and in outcomeOf).
    let resp;
    try {
      resp = await provider.send(req);
    } catch {
      // The provider may have billed before failing: settle at the worst case, never at zero.
      await ledger.settle(reservation.reservation_id, { input_tokens: 0, output_tokens: 0, cache_read_tokens: 0, usd: reserveUsd, at: clock.now() });
      attempts.push({ attempt, tier, model, stop_reason: null, outcome: "provider_error", usd: reserveUsd });
      return needsYou("provider_error", tier);
    }
    const u = resp.usage;
    const usd = (u.input_tokens * prices.in + u.output_tokens * prices.out + u.cache_read_tokens * prices.cache) / MTOK;
    await ledger.settle(reservation.reservation_id, { ...u, usd, at: clock.now() });

    // 6 and 7. Outcome, label validation, escalation.
    const { outcome, output } = outcomeOf(resp.stop_reason, resp.content, call.schema);
    attempts.push({ attempt, tier, model, stop_reason: resp.stop_reason, outcome, usd });
    if (outcome === "ok") {
      log("ok", null, tier);
      const result: RouteResult = { status: "ok", call_id, route: call.route, tier, model, content: resp.content, usd: attempts.reduce((s, a) => s + a.usd, 0), attempts };
      if (output !== undefined) result.output = output;
      return result;
    }
    const up: PaidTier | null = tier === "local" ? (paidTier ?? null) : nextTier(tier);
    if (up === null) return needsYou("escalation_exhausted", tier);
    tier = up;
  }
}
