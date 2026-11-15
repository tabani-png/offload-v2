/**
 * InMemoryBudgetLedger (m5-03): the router's BudgetLedger port in memory, shaped like the tables it stands for:
 * - `reservations` like `budget_reservations` (reserved_usd, settled_at), one per idempotency key;
 * - `entries` like `budget_entries`: append-only, one row written when a reservation settles, never updated;
 * - `usage` like `model_usage` day rows.
 * `reserve` checks the monthly and run limits and records the reservation in one synchronous step, the in-memory
 * equivalent of the row lock in ADR 0030, so parallel calls cannot overrun a budget.
 * Spend = settled entries + open reservations. Structurally matches services/brain/src/models/types.ts `BudgetLedger`.
 */

type Scope = "brain" | "run" | "design";

export interface LedgerReserveInput {
  tenant_id: string;
  idempotency_key: string;
  scope: Scope;
  scope_id: string | null;
  run_id: string | null;
  model: string;
  route: string;
  usd: number;
  at: Date;
  limits: { month_start: Date; monthly_budget_usd: number; run_budget_usd: number | null };
}

export interface LedgerSettleInput {
  input_tokens: number;
  output_tokens: number;
  cache_read_tokens: number;
  usd: number;
  at: Date;
}

export interface LedgerReservation {
  id: string;
  tenant_id: string;
  idempotency_key: string;
  scope: Scope;
  scope_id: string | null;
  run_id: string | null;
  model: string;
  route: string;
  reserved_usd: number;
  created_at: Date;
  settled_at: Date | null;
}

export interface LedgerEntry {
  id: string;
  tenant_id: string;
  idempotency_key: string;
  scope: Scope;
  scope_id: string | null;
  run_id: string | null;
  model: string;
  route: string;
  input_tokens: number;
  output_tokens: number;
  cache_read_tokens: number;
  usd: number;
  at: Date;
}

export interface ModelUsageRow {
  tenant_id: string;
  day: string;
  model: string;
  route: string;
  calls: number;
  input_tokens: number;
  output_tokens: number;
  usd: number;
}

export type ReserveResult =
  | { state: "new"; reservation_id: string }
  | { state: "open" | "settled" }
  | { state: "over_budget"; limit: "monthly" | "run" };

export class InMemoryBudgetLedger {
  readonly reservations: LedgerReservation[] = [];
  readonly entries: LedgerEntry[] = [];
  readonly usage: ModelUsageRow[] = [];
  private readonly budgets = new Map<string, number>();
  private readonly seeded = new Map<string, number>();
  private readonly defaultBudget: number;

  constructor(opts: { monthlyBudgetUsd?: number } = {}) {
    this.defaultBudget = opts.monthlyBudgetUsd ?? 50;
  }

  /** Spend already made this month outside the router (for example builds). */
  seedMonthSpend(tenant_id: string, usd: number): void {
    this.seeded.set(tenant_id, (this.seeded.get(tenant_id) ?? 0) + usd);
  }

  setMonthlyBudget(tenant_id: string, usd: number): void {
    this.budgets.set(tenant_id, usd);
  }

  async monthlyBudgetUsd(tenant_id: string): Promise<number> {
    return this.budgets.get(tenant_id) ?? this.defaultBudget;
  }

  private monthSpend(tenant_id: string, month_start: Date): number {
    const from = month_start.getTime();
    let sum = this.seeded.get(tenant_id) ?? 0;
    for (const e of this.entries) if (e.tenant_id === tenant_id && e.at.getTime() >= from) sum += e.usd;
    for (const r of this.reservations) {
      if (r.tenant_id === tenant_id && r.settled_at === null && r.created_at.getTime() >= from) sum += r.reserved_usd;
    }
    return sum;
  }

  private runSpend(run_id: string): number {
    let sum = 0;
    for (const e of this.entries) if (e.run_id === run_id) sum += e.usd;
    for (const r of this.reservations) if (r.run_id === run_id && r.settled_at === null) sum += r.reserved_usd;
    return sum;
  }

  async spentThisMonth(tenant_id: string, month_start: Date): Promise<number> {
    return this.monthSpend(tenant_id, month_start);
  }

  async spentThisRun(run_id: string): Promise<number> {
    return this.runSpend(run_id);
  }

  async reserve(input: LedgerReserveInput): Promise<ReserveResult> {
    // No await between the checks and the push: atomic with respect to other calls.
    const existing = this.reservations.find((r) => r.tenant_id === input.tenant_id && r.idempotency_key === input.idempotency_key);
    if (existing) return { state: existing.settled_at === null ? "open" : "settled" };
    const month = this.monthSpend(input.tenant_id, input.limits.month_start);
    if (input.usd > 0 && (month >= input.limits.monthly_budget_usd || month + input.usd > input.limits.monthly_budget_usd)) {
      return { state: "over_budget", limit: "monthly" };
    }
    if (input.limits.run_budget_usd !== null && input.run_id !== null && this.runSpend(input.run_id) + input.usd > input.limits.run_budget_usd) {
      return { state: "over_budget", limit: "run" };
    }
    const id = `br_${this.reservations.length + 1}`;
    this.reservations.push({
      id,
      tenant_id: input.tenant_id,
      idempotency_key: input.idempotency_key,
      scope: input.scope,
      scope_id: input.scope_id,
      run_id: input.run_id,
      model: input.model,
      route: input.route,
      reserved_usd: input.usd,
      created_at: input.at,
      settled_at: null,
    });
    return { state: "new", reservation_id: id };
  }

  async settle(reservation_id: string, actual: LedgerSettleInput): Promise<void> {
    const r = this.reservations.find((x) => x.id === reservation_id);
    if (!r) throw new Error(`unknown reservation ${reservation_id}`);
    if (r.settled_at !== null) return;
    r.settled_at = actual.at;
    this.entries.push({
      id: `be_${this.entries.length + 1}`,
      tenant_id: r.tenant_id,
      idempotency_key: r.idempotency_key,
      scope: r.scope,
      scope_id: r.scope_id,
      run_id: r.run_id,
      model: r.model,
      route: r.route,
      input_tokens: actual.input_tokens,
      output_tokens: actual.output_tokens,
      cache_read_tokens: actual.cache_read_tokens,
      usd: actual.usd,
      at: actual.at,
    });
    const day = actual.at.toISOString().slice(0, 10);
    let row = this.usage.find((u) => u.tenant_id === r.tenant_id && u.day === day && u.model === r.model && u.route === r.route);
    if (!row) {
      row = { tenant_id: r.tenant_id, day, model: r.model, route: r.route, calls: 0, input_tokens: 0, output_tokens: 0, usd: 0 };
      this.usage.push(row);
    }
    row.calls += 1;
    row.input_tokens += actual.input_tokens;
    row.output_tokens += actual.output_tokens;
    row.usd += actual.usd;
  }
}
