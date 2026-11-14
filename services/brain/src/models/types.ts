/**
 * Model router ports and shapes (m5-03, ADR 0021, ARCHITECTURE section 17).
 * The router is the one egress for product model calls; these ports keep it testable with packages/testkit fakes.
 */

export const PAID_TIERS = ["haiku", "sonnet", "opus"] as const;
export type PaidTier = (typeof PAID_TIERS)[number];
export type Tier = PaidTier | "local";

export interface ModelMessage {
  role: "user" | "assistant";
  content: string;
}

/** A JSON Schema object (label-only for router calls; see labels.ts). */
export type JsonSchema = Record<string, unknown>;

/** What a provider receives: masked, leak-scanned, budgeted. */
export interface ModelRequest {
  call_id: string;
  attempt: number;
  tier: Tier;
  model: string;
  system: string;
  messages: ModelMessage[];
  max_tokens: number;
  schema?: JsonSchema;
}

export interface ModelUsage {
  input_tokens: number;
  output_tokens: number;
  cache_read_tokens: number;
}

export interface ModelResponse {
  content: string;
  /** Messages API stop_reason (`end_turn`, `max_tokens`, `refusal`, …), mapped by local adapters. Read first. */
  stop_reason: string;
  usage: ModelUsage;
}

export interface ModelProvider {
  /** Input tokens for budgeting, counted before sending. Adapters over-count rather than under-count. */
  estimateInputTokens(req: ModelRequest): number;
  send(req: ModelRequest): Promise<ModelResponse>;
}

export type LedgerScope = "brain" | "run" | "design";

export interface BudgetLedger {
  monthlyBudgetUsd(tenant_id: string): Promise<number>;
  /** Spend since `month_start` (UTC calendar month), open reservations at their reserved amount. */
  spentThisMonth(tenant_id: string, month_start: Date): Promise<number>;
  spentThisRun(run_id: string): Promise<number>;
  /** Idempotent on (tenant_id, idempotency_key): an existing entry is returned with its state, never duplicated. */
  reserve(input: {
    tenant_id: string;
    idempotency_key: string;
    scope: LedgerScope;
    scope_id: string | null;
    run_id: string | null;
    model: string;
    route: string;
    usd: number;
    at: Date;
  }): Promise<{ reservation_id: string; state: "new" | "open" | "settled" }>;
  /** Settles a reservation with actual usage and adds to the `model_usage` day row. */
  settle(
    reservation_id: string,
    actual: { input_tokens: number; output_tokens: number; cache_read_tokens: number; usd: number; at: Date },
  ): Promise<void>;
}

/** m3-01's transport check (packages/masking detectors), consumed through this port. */
export interface LeakScanner {
  scan(text: string): Array<{ detector: string }>;
}

/** Audit writer port, shaped like packages/db appendAudit's AuditEventInput. Details hold ids and hashes only. */
export interface AuditPort {
  append(
    tenant_id: string,
    event: { principalId: string; action: string; subjectType?: string; subjectId?: string; details: Record<string, unknown> },
  ): Promise<void>;
}

export interface Clock {
  now(): Date;
}

/** Content-free log line: ids, tiers, reasons, amounts. Never text. */
export type LogLine = Record<string, string | number | boolean | null>;

export type NeedsYouReason =
  | "prices_not_configured"
  | "monthly_budget_reached"
  | "run_budget_reached"
  | "call_budget_exceeded"
  | "escalation_exhausted"
  | "call_already_settled"
  | "local_tier_off"
  | "provider_error";

export type RefusedReason =
  | "model_not_allowed"
  | "leak_blocked"
  | "untrusted_tag_escape"
  | "schema_not_label_only"
  | "unknown_route";

export type AttemptOutcome = "ok" | "refusal" | "cut_off" | "invalid_output" | "provider_error";

export interface AttemptRecord {
  attempt: number;
  tier: Tier;
  model: string;
  stop_reason: string | null;
  outcome: AttemptOutcome;
  usd: number;
}

export type RouteResult =
  | {
      status: "ok";
      call_id: string;
      route: string;
      tier: Tier;
      model: string;
      content: string;
      /** Parsed structured output when a schema was passed (labels only). */
      output?: unknown;
      usd: number;
      attempts: AttemptRecord[];
    }
  | { status: "needs_you"; call_id: string; route: string; reason: NeedsYouReason; attempts: AttemptRecord[] }
  | { status: "refused"; call_id: string; route: string; reason: RefusedReason; detectors?: string[] };
