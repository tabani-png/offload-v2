import type { PaidTier } from "./types.ts";

export type ModelStepOutcome = "clean" | "edit" | "failure" | "refusal";

export function nextTier(_tier: PaidTier): PaidTier | null {
  throw new Error("not implemented");
}

export function modelStepTier(_history: readonly ModelStepOutcome[]): "sonnet" | "haiku" {
  throw new Error("not implemented");
}
