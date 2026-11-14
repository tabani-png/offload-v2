// Merge a fresh window into the long-term propositions.
// gum (revise): same key and a similar rate -> the current version gains the evidence.
// graphiti (resolve_edge_contradictions): a rate moved by more than CONTRADICTION_RATIO -> the current version ends
// and the next version starts in the same revision group. A current belief not seen for STALE_ANALYSED_DAYS analysed
// days ends. Nothing is deleted.
import type { DayLabel } from "./ports.ts";
import type { Proposition } from "./types.ts";

export const CONTRADICTION_RATIO = 0.5;
export const STALE_ANALYSED_DAYS = 7;
export const MAX_EVIDENCE_DAYS = 180;

export interface MergeOptions {
  now: number;
  /** Every analysed day known for the member (days with a day record), including this window's. */
  analysedDays: readonly DayLabel[];
}

export function contradicts(_cur: Proposition, _fresh: Proposition): boolean {
  throw new Error("not implemented");
}
export function mergePropositions(_prior: readonly Proposition[], _fresh: readonly Proposition[], _opts: MergeOptions): Proposition[] {
  throw new Error("not implemented");
}
