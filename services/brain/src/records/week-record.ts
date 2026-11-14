// Week records (old brain/src/memory/week-record.ts): code-only rollups of the week's day records.
import type { DayLabel } from "../user-model/ports.ts";
import type { DayRecord } from "./day-record.ts";
import type { Figure } from "./figure.ts";

export const BASELINE_WEEKS = 8;

export type TaskStatus = "new" | "recurring" | "gone";

export interface WeekTask {
  task_key: string;
  name: string;
  minutes: Figure;
  instances: Figure;
  median_minutes: Figure;
  /** Median of the task's minutes in the weeks it was present among the 8 calendar weeks before; null if none. */
  baseline_minutes: Figure | null;
  /** (minutes / baseline - 1) x 100; null without a baseline. */
  vs_baseline: Figure | null;
  status: TaskStatus;
}

export interface WeekRecord {
  iso_week: string;
  from: DayLabel;
  to: DayLabel;
  days_recorded: DayLabel[];
  hours: {
    total: Figure;
    by_kind: Array<{ kind: string; hours: Figure }>;
    by_app: Array<{ app: string; hours: Figure }>;
  };
  focus: { blocks: Figure; minutes: Figure; switches_per_active_hour: Figure; meeting_hours: Figure };
  tasks: WeekTask[];
  /** Estimated vs measured savings of shipped fixes (filled from run savings in M4). */
  fixes: { estimated: Figure[]; measured: Figure[] };
  /** Recorded weeks up to and including this one. */
  weeks_observed: number;
  /** The weekly sentence, checked by checkNarrative; null until written. */
  narrative: string | null;
  generated_at: string;
}

export interface WeekInput {
  isoWeek: string;
  /** Day records of this week (any subset of its 7 days). */
  days: readonly DayRecord[];
  /** Earlier week records (any; only the 8 calendar weeks before are used). */
  prior: readonly WeekRecord[];
  weeksObserved: number;
  now: number;
}

export function buildWeekRecord(_input: WeekInput): WeekRecord {
  throw new Error("not implemented");
}
