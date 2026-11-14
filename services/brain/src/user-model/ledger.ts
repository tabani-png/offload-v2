// Task ledger (old brain/src/memory/ledger.ts): maps each induced task to a long-lived task key.
// Match order (ARCHITECTURE section 5): same signature; else same kind, app and host with masked-name Jaccard >= 0.5;
// else centroid cosine >= 0.85; else a new key. Bigger tasks claim keys first; a key is used at most once per window.
import type { DayLabel, UnderstandingWindow } from "./ports.ts";

export const NAME_MATCH = 0.5;
export const CENTROID_MATCH = 0.85;

export interface LedgerEntry {
  /** `k_` + 12 hex. */
  taskKey: string;
  /** sha256(signature), first 16 hex each. */
  signatures: string[];
  taskKind: string;
  appBundleId: string;
  host: string;
  nameWords: string[];
  name: string;
  centroid: number[] | null;
  firstSeenDay: DayLabel;
  lastSeenDay: DayLabel;
}

export interface LedgerResult {
  ledger: LedgerEntry[];
  /** window task id -> task key */
  keys: Map<string, string>;
}

export function cosine(_a: readonly number[], _b: readonly number[]): number {
  throw new Error("not implemented");
}
export function jaccard(_a: readonly string[], _b: readonly string[]): number {
  throw new Error("not implemented");
}
export function resolveTaskKeys(_prior: readonly LedgerEntry[], _window: UnderstandingWindow): LedgerResult {
  throw new Error("not implemented");
}
