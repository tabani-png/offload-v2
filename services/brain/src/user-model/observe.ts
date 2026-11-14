// Counts-only observations of the window's tasks (old brain/src/usermodel/observe.ts, rewritten for the v2 input).
import type { DayLabel, UnderstandingWindow } from "./ports.ts";
import type { DayEvidence } from "./types.ts";

export interface TaskObservation {
  taskId: string;
  taskKey: string;
  taskKind: string;
  /** Scrubbed by names.ts. */
  name: string;
  appName: string;
  host: string;
  perDay: Record<DayLabel, DayEvidence>;
  instances: number;
  firstStart: number;
  lastEnd: number;
  sameness: number;
  medianMinutes: number;
  /** The task's active time over the window's active time, 0..1. */
  share: number;
}

export function observeWindow(_window: UnderstandingWindow, _keys: ReadonlyMap<string, string>): TaskObservation[] {
  throw new Error("not implemented");
}
