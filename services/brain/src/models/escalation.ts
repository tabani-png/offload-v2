import type { PaidTier } from "./types.ts";

/** Escalation (ADR 0021): one tier up, haiku → sonnet → opus. Never down. */
const UP: Record<PaidTier, PaidTier | null> = { haiku: "sonnet", sonnet: "opus", opus: null };

export function nextTier(tier: PaidTier): PaidTier | null {
  return UP[tier];
}

export type ModelStepOutcome = "clean" | "edit" | "failure" | "refusal";

/** Clean runs in a row after which an item-level model step drops from sonnet to haiku. */
export const MODEL_STEP_CLEAN_RUNS = 5;

/**
 * Tier for an item-level model step from its run history (oldest first). Drops sonnet → haiku after 5 clean runs in a
 * row; any edit, failure or refusal sends it back to sonnet and the count starts again. Pure.
 */
export function modelStepTier(history: readonly ModelStepOutcome[]): "sonnet" | "haiku" {
  let clean = 0;
  for (const h of history) clean = h === "clean" ? clean + 1 : 0;
  return clean >= MODEL_STEP_CLEAN_RUNS ? "haiku" : "sonnet";
}
