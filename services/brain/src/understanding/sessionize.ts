// Sessionize (old brain/src/sessionize.ts, written fresh for v2's observations).
import type { CaptureObservation, CaptureText, Span } from "./types.ts";

export interface SessionOptions {
  minSpanMs: number;
  idleMergeMaxMs: number;
  idleBackdateMs: number;
}

export const SESSION: Readonly<SessionOptions> = { minSpanMs: 10_000, idleMergeMaxMs: 15 * 60_000, idleBackdateMs: 120_000 };

export function sessionize(_observations: readonly CaptureObservation[], _texts: readonly CaptureText[], _opts: SessionOptions = SESSION): Span[] {
  throw new Error("not implemented");
}
