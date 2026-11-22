// One update of a member's user model from one analysed window. Pure: the caller loads and saves (p43b job).
//   task ledger -> day records and episodes (closed days) -> observations -> propositions (merge).
import { buildDayRecords, type DayRecord, type Episode } from "../records/day-record.ts";
import { resolveTaskKeys, type LedgerEntry } from "./ledger.ts";
import { mergePropositions } from "./merge.ts";
import { observeWindow } from "./observe.ts";
import type { DayLabel, UnderstandingWindow } from "./ports.ts";
import { propose } from "./propose.ts";
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

export function updateMemberModel(window: UnderstandingWindow, state: MemberState, now: number): MemberUpdate {
  const { ledger, keys } = resolveTaskKeys(state.ledger, window);
  const { records, episodes } = buildDayRecords(window, keys, now);
  const analysedDays = [...new Set([...state.analysedDays, ...records.map((r) => r.day)])].sort();
  const fresh = propose(observeWindow(window, keys), now);
  const propositions = mergePropositions(state.propositions, fresh, { now, analysedDays });
  return { ledger, keys, dayRecords: records, episodes, propositions, analysedDays };
}
