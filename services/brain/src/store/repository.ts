// Repository for the user model's R-model tables. Every function runs inside RunInTenant: tenant_id and member_id
// are written from the transaction's app.tenant_id / app.member_id, never passed in. Rows are never deleted here
// (except figure_index rows of a re-saved record and open finder opportunities that left the top 5).
import type { RankedOpportunity } from "../opportunities/score.ts";
import type { PatchResult, Goal, Profile } from "../profile/profile.ts";
import type { DayRecord, Episode } from "../records/day-record.ts";
import type { RollupRecord } from "../records/rollup.ts";
import type { WeekRecord } from "../records/week-record.ts";
import type { ReviewAnswer } from "../review/answers.ts";
import type { ReviewOpportunity } from "../review/week-review.ts";
import type { LedgerEntry } from "../user-model/ledger.ts";
import type { Proposition } from "../user-model/types.ts";
import type { Tx } from "./tenant.ts";

/** A write would store an email address or a URL. */
export class LeakError extends Error {
  readonly code = "leak_detected";
}

export interface StoredGoal extends Goal {
  embedding: number[] | null;
}

const todo = (): never => {
  throw new Error("not implemented");
};

export const getProfile = async (_tx: Tx): Promise<Profile> => todo();
export const saveProfile = async (_tx: Tx, _r: Extract<PatchResult, { ok: true }>): Promise<Profile> => todo();
export const listGoals = async (_tx: Tx, _opts: { archived?: boolean } = {}): Promise<StoredGoal[]> => todo();
export const loadLedger = async (_tx: Tx): Promise<LedgerEntry[]> => todo();
export const saveLedger = async (_tx: Tx, _entries: readonly LedgerEntry[]): Promise<void> => todo();
export const saveEpisodes = async (_tx: Tx, _episodes: readonly Episode[]): Promise<void> => todo();
export const saveDayRecord = async (_tx: Tx, _r: DayRecord): Promise<void> => todo();
export const getDayRecord = async (_tx: Tx, _day: string): Promise<DayRecord | null> => todo();
export const listDayRecords = async (_tx: Tx, _from: string, _to: string): Promise<DayRecord[]> => todo();
export const listAnalysedDays = async (_tx: Tx): Promise<string[]> => todo();
export const saveWeekRecord = async (_tx: Tx, _r: WeekRecord): Promise<void> => todo();
export const getWeekRecord = async (_tx: Tx, _isoWeek: string): Promise<WeekRecord | null> => todo();
export const listWeekRecords = async (_tx: Tx, _from: string, _to: string): Promise<WeekRecord[]> => todo();
export const saveRollup = async (_tx: Tx, _r: RollupRecord): Promise<void> => todo();
export const getRollup = async (_tx: Tx, _kind: "month" | "quarter", _period: string): Promise<RollupRecord | null> => todo();
export const loadPropositions = async (_tx: Tx): Promise<Proposition[]> => todo();
export const savePropositions = async (_tx: Tx, _props: readonly Proposition[]): Promise<void> => todo();
export const saveReviewAnswer = async (_tx: Tx, _a: ReviewAnswer): Promise<ReviewAnswer> => todo();
export const listReviewAnswers = async (_tx: Tx): Promise<ReviewAnswer[]> => todo();
export const saveOpportunities = async (_tx: Tx, _input: { isoWeek: string; workspaceId: string; ranked: readonly RankedOpportunity[]; now: number }): Promise<void> => todo();
export const listOpportunities = async (_tx: Tx, _isoWeek: string): Promise<Array<ReviewOpportunity & { id: string; score: number; goal_id: string | null; factors: RankedOpportunity["factors"] }>> => todo();
/** Applies a review answer to the week's finder opportunity for that task (declines; a later keep reopens). */
export const applyAnswerToOpportunity = async (_tx: Tx, _a: ReviewAnswer): Promise<void> => todo();
/** The retention job marks a day whose raw evidence passed its TTL: values kept, figures re-indexed. */
export const markSourcePurged = async (_tx: Tx, _day: string, _at: string): Promise<void> => todo();
export const resolveFigure = async (_tx: Tx, _figureId: string): Promise<{ record_kind: string; record_key: string; json_pointer: string } | null> => todo();
