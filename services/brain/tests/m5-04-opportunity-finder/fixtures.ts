// Hand-built week records, episodes and task evidence for the m5-04 tests. Synthetic: hosts are launch-catalog hosts
// or `.example` hosts, task names are made up.
import type { Episode } from "../../src/records/day-record.ts";
import { figure, type Figure } from "../../src/records/figure.ts";
import type { WeekRecord, WeekTask } from "../../src/records/week-record.ts";
import type { TaskEvidence } from "../../src/opportunities/types.ts";

const zero = (unit: Figure["unit"]) => figure(0, unit, "none", []);

export interface TaskRow {
  task_key: string;
  name: string;
  minutes: number;
  instances: number;
  median: number;
}

export function weekTask(t: TaskRow): WeekTask {
  return {
    task_key: t.task_key, name: t.name,
    minutes: figure(t.minutes, "minutes", `fixture ${t.minutes}`, []),
    instances: figure(t.instances, "count", `fixture ${t.instances}`, []),
    median_minutes: figure(t.median, "minutes", `fixture ${t.median}`, []),
    baseline_minutes: null, vs_baseline: null, status: "new",
  };
}

/** A week record holding only `tasks` (other figures zero). */
export function weekWith(isoWeek: string, from: string, to: string, tasks: readonly TaskRow[], weeksObserved = 1): WeekRecord {
  return {
    iso_week: isoWeek, from, to, days_recorded: [from],
    hours: { total: zero("hours"), by_kind: [], by_app: [] },
    focus: { blocks: zero("count"), minutes: zero("minutes"), switches_per_active_hour: zero("per_hour"), meeting_hours: zero("hours") },
    tasks: tasks.map(weekTask), fixes: { estimated: [], measured: [] }, weeks_observed: weeksObserved, narrative: null,
    generated_at: "2026-11-09T12:00:00.000Z",
  };
}

/** A task-instance episode starting at `start` (ISO, UTC). */
export function ep(id: string, taskKey: string, start: string, minutes: number, apps: string[], hosts: string[], day = start.slice(0, 10)): Episode {
  const s = Date.parse(start);
  return {
    id, kind: "task_instance", day, started_at: new Date(s).toISOString(), ended_at: new Date(s + minutes * 60_000).toISOString(), minutes,
    apps, hosts, task_key: taskKey, name: "fixture task", evidence: [], source_purged_at: null,
  };
}

/** Task evidence with defaults: 60 min, 6 instances, median 10, 3 days, no cadence. */
export function ev(p: Partial<TaskEvidence> & Pick<TaskEvidence, "systems">): TaskEvidence {
  return {
    task_key: "k_000000000001", name: "Copy payouts into the books", iso_week: "2026-W45", minutes: 60, instances: 6, median_minutes: 10, days: 3,
    cadence: null, episode_ids: ["ep_a", "ep_b"], ...p,
  };
}

export const STRIPE = { id: "dashboard.stripe.com", surface: "web", work_kind: "browse" } as const;
export const QBO = { id: "qbo.intuit.com", surface: "web", work_kind: "browse" } as const;
export const GMAIL = { id: "mail.google.com", surface: "web", work_kind: "email" } as const;
export const GDOCS = { id: "docs.google.com", surface: "web", work_kind: "docs" } as const;
export const LEDGERLY = { id: "app.ledgerly.example", surface: "web", work_kind: "browse" } as const;
export const EXCEL = { id: "com.microsoft.Excel", surface: "desktop", work_kind: "sheet" } as const;
export const VSCODE = { id: "com.microsoft.VSCode", surface: "desktop", work_kind: "code" } as const;
export const ZOOM = { id: "us.zoom.xos", surface: "desktop", work_kind: "meeting" } as const;
export const SLACK = { id: "com.tinyspeck.slackmacgap", surface: "desktop", work_kind: "chat" } as const;

/** Evaluates a figure's arithmetic left of " = ": "x" is multiplication, words are labels. */
export function evalArithmetic(arithmetic: string): number {
  const lhs = arithmetic.split(" = ")[0]!.replaceAll(" x ", " * ").replace(/[A-Za-z_]+/g, " ");
  if (!/^[\d.\s()+\-*/]+$/.test(lhs)) throw new Error(`not arithmetic: ${arithmetic}`);
  return Function(`"use strict"; return (${lhs});`)() as number;
}
