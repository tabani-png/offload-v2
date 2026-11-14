/**
 * InMemoryBudgetLedger (m5-03): the router's BudgetLedger port in memory. Append-only entries keyed by
 * (tenant_id, idempotency_key) like `budget_entries`, plus `model_usage` day rows. An open reservation counts at its
 * reserved amount; a settled entry counts at its actual amount. Structurally matches
 * services/brain/src/models/types.ts `BudgetLedger`. The Postgres adapter is a later slice.
 */

export interface LedgerReserveInput {
  tenant_id: string;
  idempotency_key: string;
  scope: "brain" | "run" | "design";
  scope_id: string | null;
  run_id: string | null;
  model: string;
  route: string;
  usd: number;
  at: Date;
}

export interface LedgerSettleInput {
  input_tokens: number;
  output_tokens: number;
  cache_read_tokens: number;
  usd: number;
  at: Date;
}

export interface LedgerEntry {
  id: string;
  tenant_id: string;
  idempotency_key: string;
  scope: "brain" | "run" | "design";
  scope_id: string | null;
  run_id: string | null;
  model: string;
  route: string;
  reserved_usd: number;
  state: "open" | "settled";
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

export interface ReserveResult {
  reservation_id: string;
  state: "new" | "open" | "settled";
}

export class InMemoryBudgetLedger {
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

  async spentThisMonth(tenant_id: string, month_start: Date): Promise<number> {
    let sum = this.seeded.get(tenant_id) ?? 0;
    for (const e of this.entries) {
      if (e.tenant_id === tenant_id && e.at.getTime() >= month_start.getTime()) sum += counted(e);
    }
    return sum;
  }

  async spentThisRun(run_id: string): Promise<number> {
    let sum = 0;
    for (const e of this.entries) if (e.run_id === run_id) sum += counted(e);
    return sum;
  }

  async reserve(input: LedgerReserveInput): Promise<ReserveResult> {
    const existing = this.entries.find(
      (e) => e.tenant_id === input.tenant_id && e.idempotency_key === input.idempotency_key,
    );
    if (existing) return { reservation_id: existing.id, state: existing.state };
    const id = `be_${this.entries.length + 1}`;
    this.entries.push({
      id,
      tenant_id: input.tenant_id,
      idempotency_key: input.idempotency_key,
      scope: input.scope,
      scope_id: input.scope_id,
      run_id: input.run_id,
      model: input.model,
      route: input.route,
      reserved_usd: input.usd,
      state: "open",
      input_tokens: 0,
      output_tokens: 0,
      cache_read_tokens: 0,
      usd: 0,
      at: input.at,
    });
    return { reservation_id: id, state: "new" };
  }

  async settle(reservation_id: string, actual: LedgerSettleInput): Promise<void> {
    const e = this.entries.find((x) => x.id === reservation_id);
    if (!e) throw new Error(`unknown reservation ${reservation_id}`);
    if (e.state === "settled") return;
    e.state = "settled";
    e.input_tokens = actual.input_tokens;
    e.output_tokens = actual.output_tokens;
    e.cache_read_tokens = actual.cache_read_tokens;
    e.usd = actual.usd;
    const day = actual.at.toISOString().slice(0, 10);
    let row = this.usage.find((u) => u.tenant_id === e.tenant_id && u.day === day && u.model === e.model && u.route === e.route);
    if (!row) {
      row = { tenant_id: e.tenant_id, day, model: e.model, route: e.route, calls: 0, input_tokens: 0, output_tokens: 0, usd: 0 };
      this.usage.push(row);
    }
    row.calls += 1;
    row.input_tokens += actual.input_tokens;
    row.output_tokens += actual.output_tokens;
    row.usd += actual.usd;
  }
}

function counted(e: LedgerEntry): number {
  return e.state === "open" ? e.reserved_usd : e.usd;
}
