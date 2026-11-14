// Day records and episodes (old brain/src/memory/day-record.ts): one record per closed member-timezone day, code only.
import type { DayLabel, UnderstandingWindow } from "../user-model/ports.ts";
import type { Figure } from "./figure.ts";
import type { WorkKind } from "./kinds.ts";

export const FOCUS_BLOCK_MINUTES = 25;
export const FOCUS_GAP_SECONDS = 120;

export interface Episode {
  /** `ep_` + instance id, or `ep_fb_` + 12 hex for a focus block. */
  id: string;
  kind: "focus_block" | "task_instance";
  day: DayLabel;
  started_at: string;
  ended_at: string;
  minutes: number;
  apps: string[];
  task_key: string | null;
  /** Masked verb-object name. */
  name: string;
  /** Observation ids. */
  evidence: string[];
  source_purged_at: string | null;
}

export interface DayRecord {
  day: DayLabel;
  generated_at: string;
  totals: {
    active_minutes: Figure;
    switches: Figure;
    switches_per_active_hour: Figure;
    focus_blocks: Figure;
    focus_minutes: Figure;
    meeting_minutes: Figure;
  };
  by_kind: Array<{ kind: WorkKind; minutes: Figure }>;
  by_app: Array<{ app: string; minutes: Figure }>;
  by_task: Array<{ task_key: string; name: string; minutes: Figure; instances: Figure; median_minutes: Figure }>;
  episode_ids: string[];
  source_purged_at: string | null;
}

/** Records for every closed day of the window (days before today in the member's timezone at `now`). */
export function buildDayRecords(
  _window: UnderstandingWindow,
  _keys: ReadonlyMap<string, string>,
  _now: number,
): { records: DayRecord[]; episodes: Episode[] } {
  throw new Error("not implemented");
}
