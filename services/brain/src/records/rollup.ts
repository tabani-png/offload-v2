// Month and quarter records: rollups of week records (old week-record.ts rollups). Trend = Theil-Sen slope of weekly
// minutes over (week index, minutes) points, so a missing week keeps its place on the x axis.
import type { Figure } from "./figure.ts";
import type { WeekRecord } from "./week-record.ts";

export const MIN_TREND_WEEKS = 3;
export const MONTH_PERSISTENCE = 0.75;
export const QUARTER_PERSISTENCE = 8 / 13;
/** A drain is confirmed when its kinds of work take at least this share of the period's hours. */
export const DRAIN_CONFIRM_SHARE = 0.15;

export interface RollupRecord {
  kind: "month" | "quarter";
  /** `YYYY-MM` or `YYYY-Qn`. */
  period: string;
  weeks: string[];
  hours: { total: Figure };
  by_task: Array<{ task_key: string; name: string; minutes: Figure; weeks_present: Figure }>;
  persistent: string[];
  trend: Array<{ task_key: string; name: string; slope_minutes_per_week: Figure }>;
  drift: { drains: Array<{ drain: string; verdict: "confirmed" | "refuted"; share: Figure }> };
  notes: string[];
  narrative: string | null;
  generated_at: string;
}

/** Theil-Sen slope: the median of all pairwise slopes, rounded to 0.1. null with fewer than 2 points. */
export function theilSen(_points: ReadonlyArray<{ x: number; y: number }>): number | null {
  throw new Error("not implemented");
}

/** Month or quarter record from the week records available (others are ignored). null when no week is in it. */
export function buildRollup(
  _kind: "month" | "quarter",
  _period: string,
  _weeks: readonly WeekRecord[],
  _drains: readonly string[],
  _now: number,
): RollupRecord | null {
  throw new Error("not implemented");
}
