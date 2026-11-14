// The member update job: runs the p43a pipeline for one analysed window inside one tenant transaction and saves it.
// Called by the durable runtime (W1-C, m5-05) per member; running it twice with the same window leaves the same rows.
// No network I/O: the weekly sentence is written by writeWeekNarrative, outside the data transaction.
import type { FixEstimate } from "../opportunities/score.ts";
import type { WeekTask } from "../records/week-record.ts";
import type { CompleteText, UnderstandingWindow } from "../user-model/ports.ts";
import type { RunInTenant, TenantContext, Tx } from "./tenant.ts";

export interface MemberUpdateInput {
  window: UnderstandingWindow;
  now: number;
  workspaceId: string;
  /** Fix rules for a week's task (m5-04 port); null = no fix proposed. */
  estimateFor?: (task: WeekTask) => Omit<FixEstimate, "taskKey"> | null;
  taskVectors?: ReadonlyMap<string, readonly number[]>;
  trackRecord?: ReadonlyMap<string, number>;
}

export interface MemberUpdateResult {
  days: string[];
  weeks: string[];
  months: string[];
  quarters: string[];
  ranked: number;
}

export async function runMemberUpdate(_tx: Tx, _input: MemberUpdateInput): Promise<MemberUpdateResult> {
  throw new Error("not implemented");
}

/** Reads the week (transaction 1), asks the model outside any transaction, stores a checked sentence (transaction 2). */
export async function writeWeekNarrative(_run: RunInTenant, _ctx: TenantContext, _isoWeek: string, _complete: CompleteText | null): Promise<"model" | "code" | "none"> {
  throw new Error("not implemented");
}
