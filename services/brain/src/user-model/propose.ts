// Observations -> propositions. gum asks a model for confidence and decay; here both are computed by rule from
// evidence counts (ADR 0003), and the text is a template over the counts.
import type { TaskObservation } from "./observe.ts";
import type { Proposition, PropositionEvidence, PropositionKind } from "./types.ts";

export const MIN_REPEATS = 3;
export const MIN_SHARE = 0.05;
export const CONFIDENT_DAYS = 10;
export const DURABLE_DAYS = 14;

export function propositionId(_key: string, _version: number): string {
  throw new Error("not implemented");
}
export function confidenceScore(_e: Pick<PropositionEvidence, "days" | "instances" | "sameness">): number {
  throw new Error("not implemented");
}
export function confidenceOf(_score: number): number {
  throw new Error("not implemented");
}
export function decayOf(_e: Pick<PropositionEvidence, "days">): number {
  throw new Error("not implemented");
}
export function rateOf(_kind: PropositionKind, _e: PropositionEvidence): number {
  throw new Error("not implemented");
}
/** Recounts instances, days, minutes and day list from `perDay`, then rate, confidence, decay and text. */
export function finish(_p: Proposition): Proposition {
  throw new Error("not implemented");
}
/** Fresh version-1 propositions for one window. Deterministic, sorted by key. */
export function propose(_observations: readonly TaskObservation[], _now: number): Proposition[] {
  throw new Error("not implemented");
}
