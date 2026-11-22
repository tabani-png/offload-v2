// Observations in, understanding window out.
import type { DayLabel, UnderstandingWindow } from "../user-model/ports.ts";
import type { Embedder } from "./embed.ts";
import type { SpanLabeler } from "./labeler.ts";
import type { CaptureObservation, CaptureText } from "./types.ts";

export interface WindowInput {
  timezone: string;
  days: DayLabel[];
  observations: readonly CaptureObservation[];
  texts: readonly CaptureText[];
}

export interface WindowDeps {
  embedder?: Embedder;
  labeler?: SpanLabeler;
}

export async function buildUnderstandingWindow(_input: WindowInput, _deps: WindowDeps = {}): Promise<UnderstandingWindow> {
  throw new Error("not implemented");
}
