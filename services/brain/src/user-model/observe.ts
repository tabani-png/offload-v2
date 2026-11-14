// Counts-only observations of the window's tasks (old brain/src/usermodel/observe.ts, rewritten for the v2 input).
// No title, text or observation id leaves this function: only keys, masked names, counts and minutes.
import { r1, r2 } from "../records/figure.ts";
import { dayOf } from "../records/dates.ts";
import { taskName } from "./names.ts";
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

export function median(xs: readonly number[]): number {
  if (xs.length === 0) return 0;
  const s = [...xs].sort((a, b) => a - b);
  const m = Math.floor(s.length / 2);
  return s.length % 2 === 1 ? s[m]! : (s[m - 1]! + s[m]!) / 2;
}

const r4 = (x: number) => Math.round(x * 1e4) / 1e4;

export function observeWindow(window: UnderstandingWindow, keys: ReadonlyMap<string, string>): TaskObservation[] {
  const total = window.spans.reduce((n, s) => n + s.activeSeconds, 0);
  const out: TaskObservation[] = [];
  for (const t of window.tasks) {
    const taskKey = keys.get(t.id);
    if (taskKey === undefined || t.instances.length === 0) continue;
    const secs = new Map<DayLabel, { instances: number; seconds: number }>();
    for (const i of t.instances) {
      const d = dayOf(i.start, window.timezone);
      const x = secs.get(d) ?? { instances: 0, seconds: 0 };
      x.instances += 1;
      x.seconds += i.activeSeconds;
      secs.set(d, x);
    }
    const sameness = r4(Math.min(1, Math.max(0, t.sameness)));
    const perDay: Record<DayLabel, DayEvidence> = {};
    for (const d of [...secs.keys()].sort()) perDay[d] = { instances: secs.get(d)!.instances, minutes: r2(secs.get(d)!.seconds / 60), sameness };
    const mine = t.instances.reduce((n, i) => n + i.activeSeconds, 0);
    out.push({
      taskId: t.id, taskKey, taskKind: t.kind, name: taskName(t.name, t.kind), appName: t.appName, host: t.host, perDay,
      instances: t.instances.length,
      firstStart: Math.min(...t.instances.map((i) => i.start)),
      lastEnd: Math.max(...t.instances.map((i) => i.end)),
      sameness, medianMinutes: r1(median(t.instances.map((i) => i.activeSeconds / 60))),
      share: total === 0 ? 0 : r4(mine / total),
    });
  }
  return out.sort((x, y) => (x.taskKey < y.taskKey ? -1 : x.taskKey > y.taskKey ? 1 : 0));
}
