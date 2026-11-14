import type { ModelsConfig } from "./config.ts";
import type { AuditPort, BudgetLedger, Clock, JsonSchema, LeakScanner, LedgerScope, LogLine, ModelMessage, ModelProvider, RouteResult } from "./types.ts";

export interface RouteCall {
  call_id?: string;
  tenant_id: string;
  member_id?: string;
  run_id?: string;
  route: string;
  system: string;
  messages: ModelMessage[];
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
  log?: (line: LogLine) => void;
}

export async function route(_call: RouteCall, _deps: RouterDeps): Promise<RouteResult> {
  throw new Error("not implemented");
}
