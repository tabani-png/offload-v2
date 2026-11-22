// Task induction.
import type { WindowTask } from "../user-model/ports.ts";
import type { SpanDescription } from "./types.ts";

export interface InduceOptions {
  assignThreshold: number;
  instanceGapMs: number;
  linkGapMs: number;
  itemMaxSpans: number;
  transitionGapMs: number;
  transitionMinCount: number;
  transitionMinShare: number;
}

export const INDUCE: Readonly<InduceOptions> = {
  assignThreshold: 0.7, instanceGapMs: 10 * 60_000, linkGapMs: 20 * 60_000, itemMaxSpans: 12, transitionGapMs: 2 * 60_000,
  transitionMinCount: 2, transitionMinShare: 0.5,
};

export function induceTasks(_descs: readonly SpanDescription[], _vectors: ReadonlyMap<string, readonly number[]>, _timezone: string, _opts: InduceOptions = INDUCE): WindowTask[] {
  throw new Error("not implemented");
}
