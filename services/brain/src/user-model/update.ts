// One update of a member's user model from one analysed window. Pure: the caller loads and saves (p43b job).
//   task ledger -> day records and episodes (closed days) -> observations -> propositions (merge).
import type { DayRecord, Episode } from "../records/day-record.ts";
import type { LedgerEntry } from "./ledger.ts";
import type { DayLabel, UnderstandingWindow } from "./ports.ts";
import type { Proposition } from "./types.ts";

export interface MemberState {
  ledger: readonly LedgerEntry[];
  propositions: readonly Proposition[];
  /** Days that already have a day record. */
  analysedDays: readonly DayLabel[];
}

export interface MemberUpdate {
  ledger: LedgerEntry[];
  keys: Map<string, string>;
  dayRecords: DayRecord[];
  episodes: Episode[];
  propositions: Proposition[];
  analysedDays: DayLabel[];
}

export function updateMemberModel(_window: UnderstandingWindow, _state: MemberState, _now: number): MemberUpdate {
  throw new Error("not implemented");
}
