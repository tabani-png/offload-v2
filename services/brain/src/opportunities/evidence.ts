// Task evidence for the fix rules (slice m5-04, SPEC Design note 1). Pure.
import type { Episode } from "../records/day-record.ts";
import type { WeekRecord } from "../records/week-record.ts";
import type { TaskEvidence } from "./types.ts";

export interface EvidenceInput {
  week: WeekRecord;
  /** Task-instance episodes of the last 8 weeks up to this one, read through day_records.episode_ids. */
  episodes: readonly Episode[];
  timezone: string;
}

export function buildTaskEvidence(_input: EvidenceInput): TaskEvidence[] {
  throw new Error("not implemented");
}
