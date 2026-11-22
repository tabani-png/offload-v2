import { jcs, sha256Hex } from "@offload/contracts";
import {
  ResolvedRoutineDefinitionSchema, type ResolvedRoutineDefinition, type ResolvedStep, type RoutineDefinition,
} from "./routine.ts";

/** A connection the brief pins (ADR 0033): the runtime never re-resolves it. */
export type PinnedTool = { capability: string; tool_name: string; tool_pin_hash: string };
export type PinnedConnection = {
  connection_ref: string;
  connection_id: string;
  adapter: string;
  provider: string;
  account_label: string;
  tools: PinnedTool[];
};
/** The parts of a fix brief the deploy checks read. */
export type Brief = { capabilities: readonly string[]; connections: readonly PinnedConnection[] };

export class ResolveError extends Error {
  override name = "ResolveError";
}

export type ManifestErrorCode = "capability_not_in_brief" | "connection_not_in_brief";
export class ManifestError extends Error {
  override name = "ManifestError";
  constructor(readonly code: ManifestErrorCode, message: string) {
    super(message);
  }
}

/**
 * Fills each connector step's connection_id, adapter, provider, account_label, tool_name and tool_pin_hash from the
 * brief's pinned connections. Throws ResolveError when a connection or a tool pin is missing.
 */
export function resolveDefinition(def: RoutineDefinition, pins: readonly PinnedConnection[]): ResolvedRoutineDefinition {
  const byRef = new Map<string, PinnedConnection>();
  for (const p of pins) {
    if (byRef.has(p.connection_ref)) throw new ResolveError(`connection ${p.connection_ref} is pinned twice`);
    byRef.set(p.connection_ref, p);
  }
  const steps = def.steps.map((step) => {
    if (!("connection_ref" in step)) return step;
    const pin = byRef.get(step.connection_ref);
    if (!pin) throw new ResolveError(`step ${step.id}: connection ${step.connection_ref} is not pinned in the brief`);
    const tools = pin.tools.filter((t) => t.capability === step.capability);
    if (tools.length !== 1) {
      throw new ResolveError(`step ${step.id}: connection ${step.connection_ref} needs exactly one tool pin for ${step.capability}`);
    }
    const tool = tools[0]!;
    return {
      ...step, connection_id: pin.connection_id, adapter: pin.adapter, provider: pin.provider,
      account_label: pin.account_label, tool_name: tool.tool_name, tool_pin_hash: tool.tool_pin_hash,
    };
  });
  return ResolvedRoutineDefinitionSchema.parse({ ...def, steps });
}

/** definition_hash = sha256Hex(JCS(resolved routine.json)) (ADR 0032). Validates the resolved definition first. */
export function definitionHash(resolved: ResolvedRoutineDefinition): string {
  return sha256Hex(jcs(ResolvedRoutineDefinitionSchema.parse(resolved)));
}

/**
 * The definition in plain words for the deploy screen (ADR 0032): trigger, each step with its capability and which
 * account, and the limits. Written by code from the definition, never by a model.
 */
export function describeDefinition(resolved: ResolvedRoutineDefinition): string[] {
  const def = ResolvedRoutineDefinitionSchema.parse(resolved);
  const t = def.trigger;
  const lines: string[] = [];
  switch (t.kind) {
    case "schedule":
      lines.push(`Runs on the schedule "${t.cron}" (${t.timezone ?? "your time zone"}).`);
      break;
    case "manual":
      lines.push("Runs when you start it.");
      break;
    case "webhook":
      lines.push("Runs when its webhook is called.");
      break;
    case "event":
      lines.push(`Runs on the Offload event "${t.event_type}".`);
      break;
  }
  for (const s of def.steps) lines.push(`Step ${s.id}: ${describeStep(s)}`);
  const l = def.limits;
  const count = (n: number, one: string, many: string) => `${n} ${n === 1 ? one : many}`;
  lines.push(
    `At most ${count(l.max_items_per_run, "item", "items")} a run and ${count(l.max_runs_per_day, "run", "runs")} a day. ` +
      `Run budget $${l.run_budget_usd.toFixed(2)}.`,
  );
  lines.push(l.quiet_hours ? `Quiet hours ${l.quiet_hours.start} to ${l.quiet_hours.end}.` : "No quiet hours.");
  if (l.recipients_from !== undefined) lines.push(`Recipients only from step ${l.recipients_from}.`);
  return lines;
}

function describeStep(s: ResolvedStep): string {
  const each = s.foreach === undefined ? "" : ` for each item from step ${s.foreach}`;
  switch (s.class) {
    case "read":
      return `reads ${s.capability} (${s.provider} · ${s.account_label})${each}.`;
    case "draft":
      return `drafts ${s.capability} (${s.provider} · ${s.account_label})${each}. Sends nothing.`;
    case "commit":
      return s.runs_on === "device"
        ? `commits ${s.capability} on your Mac (${s.provider} · ${s.account_label})${each}.`
        : `commits ${s.capability} (${s.provider} · ${s.account_label})${each}.`;
    case "transform":
      return `runs ${s.transform}${each}, with no network.`;
    case "model":
      return `asks model route ${s.model.route} for structured output${each}, with no tools.`;
  }
}

/**
 * Deploy check (ADR 0026): def.capabilities ⊆ brief.capabilities and every step's connection_ref is a connection the
 * brief pins. Throws ManifestError. The third deploy check, every transform loads in the isolate, is loadTransform.
 */
export function checkManifest(def: RoutineDefinition, brief: Brief): void {
  const allowed = new Set(brief.capabilities);
  for (const c of def.capabilities) {
    if (!allowed.has(c)) throw new ManifestError("capability_not_in_brief", `capability ${c} is not in the brief`);
  }
  const refs = new Set(brief.connections.map((c) => c.connection_ref));
  for (const s of def.steps) {
    if ("connection_ref" in s && !refs.has(s.connection_ref)) {
      throw new ManifestError("connection_not_in_brief", `step ${s.id}: connection ${s.connection_ref} is not in the brief`);
    }
  }
}
