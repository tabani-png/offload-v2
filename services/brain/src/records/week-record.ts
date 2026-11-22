// Week records (old brain/src/memory/week-record.ts): code-only rollups of the week's day records.
// v2 fixes: the baseline looks at the 8 calendar weeks before (not the last 8 stored ones), and weeks_observed is
// supplied by the caller (the count of every recorded week), not capped by the baseline window.
import type { DayLabel } from "../user-model/ports.ts";
import { median } from "../user-model/observe.ts";
import { addWeeks, isoWeekOf, weekDays } from "./dates.ts";
import type { DayRecord } from "./day-record.ts";
import { figure, r1, r2, type EvidenceRef, type Figure } from "./figure.ts";

export const BASELINE_WEEKS = 8;

export type TaskStatus = "new" | "recurring" | "gone";

export interface WeekTask {
  task_key: string;
  name: string;
  minutes: Figure;
  instances: Figure;
  median_minutes: Figure;
  /** Median of the task's minutes in the weeks it was present among the 8 calendar weeks before; null if none. */
  baseline_minutes: Figure | null;
  /** (minutes / baseline - 1) x 100; null without a baseline. */
  vs_baseline: Figure | null;
  status: TaskStatus;
}

export interface WeekRecord {
  iso_week: string;
  from: DayLabel;
  to: DayLabel;
  days_recorded: DayLabel[];
  hours: {
    total: Figure;
    by_kind: Array<{ kind: string; hours: Figure }>;
    by_app: Array<{ app: string; hours: Figure }>;
  };
  focus: { blocks: Figure; minutes: Figure; switches_per_active_hour: Figure; meeting_hours: Figure };
  tasks: WeekTask[];
  /** Estimated vs measured savings of shipped fixes (filled from run savings in M4). */
  fixes: { estimated: Figure[]; measured: Figure[] };
  /** Recorded weeks up to and including this one. */
  weeks_observed: number;
  /** The weekly sentence, checked by checkNarrative; null until written. */
  narrative: string | null;
  generated_at: string;
}

export interface WeekInput {
  isoWeek: string;
  /** Day records of this week (any subset of its 7 days). */
  days: readonly DayRecord[];
  /** Earlier week records (any; only the 8 calendar weeks before are used). */
  prior: readonly WeekRecord[];
  weeksObserved: number;
  now: number;
}

const sumBy = <T>(rows: readonly T[], key: (r: T) => string, value: (r: T) => number) => {
  const m = new Map<string, number>();
  for (const r of rows) m.set(key(r), (m.get(key(r)) ?? 0) + value(r));
  return m;
};
const byValue = <T extends { hours: Figure }>(key: (x: T) => string) => (a: T, b: T) => b.hours.value - a.hours.value || (key(a) < key(b) ? -1 : 1);

export function buildWeekRecord(input: WeekInput): WeekRecord {
  const { isoWeek } = input;
  const days = weekDays(isoWeek);
  const recs = input.days.filter((d) => isoWeekOf(d.day) === isoWeek).sort((a, b) => (a.day < b.day ? -1 : 1));
  const dayRefs: EvidenceRef[] = recs.map((d) => ({ kind: "day_record", id: d.day }));
  const oldest = addWeeks(isoWeek, -BASELINE_WEEKS);
  const prior = input.prior.filter((w) => w.iso_week >= oldest && w.iso_week < isoWeek).sort((a, b) => (a.iso_week < b.iso_week ? -1 : 1));
  const weekRefs = (ws: readonly WeekRecord[]): EvidenceRef[] => ws.map((w) => ({ kind: "week_record", id: w.iso_week }));

  const totalMin = recs.reduce((n, r) => n + r.totals.active_minutes.value, 0);
  const tasks = new Map<string, { name: string; minutes: number; instances: number; medians: number[]; days: DayLabel[] }>();
  for (const r of recs) for (const t of r.by_task) {
    const x = tasks.get(t.task_key) ?? { name: t.name, minutes: 0, instances: 0, medians: [], days: [] };
    x.name = t.name;
    x.minutes += t.minutes.value;
    x.instances += t.instances.value;
    x.medians.push(t.median_minutes.value);
    x.days.push(r.day);
    tasks.set(t.task_key, x);
  }
  const present = (key: string) => prior.map((w) => ({ w, m: w.tasks.find((t) => t.task_key === key && t.minutes.value > 0)?.minutes.value })).filter((x): x is { w: WeekRecord; m: number } => x.m !== undefined);
  const baselineOf = (key: string): Figure | null => {
    const before = present(key);
    if (before.length === 0) return null;
    const b = r1(median(before.map((x) => x.m)));
    return figure(b, "minutes", `median of the task's minutes in ${before.length} of the ${BASELINE_WEEKS} weeks before ${isoWeek} = ${b} min`, weekRefs(before.map((x) => x.w)));
  };
  const out: WeekTask[] = [];
  for (const [key, x] of tasks) {
    const minutes = r1(x.minutes);
    const baseline = baselineOf(key);
    const vs = baseline === null || baseline.value === 0 ? null : r1((minutes / baseline.value - 1) * 100);
    const refs: EvidenceRef[] = x.days.map((d) => ({ kind: "day_record", id: d }));
    const med = r1(median(x.medians));
    out.push({
      task_key: key, name: x.name,
      minutes: figure(minutes, "minutes", `sum of the task's minutes on ${x.days.length} days = ${minutes} min`, refs),
      instances: figure(x.instances, "count", `sum of the task's instances on ${x.days.length} days = ${x.instances}`, refs),
      median_minutes: figure(med, "minutes", `median of ${x.medians.length} daily medians = ${med} min`, refs),
      baseline_minutes: baseline,
      vs_baseline: vs === null ? null : figure(vs, "percent", `(${minutes} min / ${baseline!.value} min - 1) x 100 = ${vs}%`, [...refs, ...baseline!.evidence]),
      status: baseline === null ? "new" : "recurring",
    });
  }
  const last = prior.find((w) => w.iso_week === addWeeks(isoWeek, -1));
  for (const t of last?.tasks ?? []) {
    if (t.minutes.value === 0 || tasks.has(t.task_key)) continue;
    const baseline = baselineOf(t.task_key);
    out.push({
      task_key: t.task_key, name: t.name,
      minutes: figure(0, "minutes", `no instances in ${isoWeek}`, dayRefs),
      instances: figure(0, "count", `no instances in ${isoWeek}`, dayRefs),
      median_minutes: figure(0, "minutes", `no instances in ${isoWeek}`, dayRefs),
      baseline_minutes: baseline,
      vs_baseline: baseline === null || baseline.value === 0 ? null : figure(-100, "percent", `(0 min / ${baseline.value} min - 1) x 100 = -100%`, baseline.evidence),
      status: "gone",
    });
  }
  out.sort((a, b) => b.minutes.value - a.minutes.value || (a.task_key < b.task_key ? -1 : 1));

  const hours = r2(totalMin / 60);
  const switches = recs.reduce((n, r) => n + r.totals.switches.value, 0);
  const perHour = totalMin === 0 ? 0 : r1(switches / (totalMin / 60));
  const blocks = recs.reduce((n, r) => n + r.totals.focus_blocks.value, 0);
  const focusMin = r1(recs.reduce((n, r) => n + r.totals.focus_minutes.value, 0));
  const meetingH = r2(recs.reduce((n, r) => n + r.totals.meeting_minutes.value, 0) / 60);
  const kindH = sumBy(recs.flatMap((r) => r.by_kind), (k) => k.kind, (k) => k.minutes.value);
  const appH = sumBy(recs.flatMap((r) => r.by_app), (a) => a.app, (a) => a.minutes.value);
  return {
    iso_week: isoWeek, from: days[0]!, to: days[6]!, days_recorded: recs.map((r) => r.day),
    hours: {
      total: figure(hours, "hours", `sum of ${recs.length} day records' active minutes (${r1(totalMin)} min) / 60 = ${hours} h`, dayRefs),
      by_kind: [...kindH].map(([kind, m]) => ({ kind, hours: figure(r2(m / 60), "hours", `${kind} minutes of ${recs.length} day records (${r1(m)} min) / 60`, dayRefs) })).sort(byValue((x) => x.kind)),
      by_app: [...appH].map(([app, m]) => ({ app, hours: figure(r2(m / 60), "hours", `minutes in ${app} on ${recs.length} day records (${r1(m)} min) / 60`, dayRefs) })).sort(byValue((x) => x.app)),
    },
    focus: {
      blocks: figure(blocks, "count", `sum of focus blocks on ${recs.length} days = ${blocks}`, dayRefs),
      minutes: figure(focusMin, "minutes", `sum of focus minutes on ${recs.length} days = ${focusMin} min`, dayRefs),
      switches_per_active_hour: figure(perHour, "per_hour", `${switches} switches / (${r1(totalMin)} min / 60) = ${perHour} per active hour`, dayRefs),
      meeting_hours: figure(meetingH, "hours", `sum of meeting minutes on ${recs.length} days / 60 = ${meetingH} h`, dayRefs),
    },
    tasks: out,
    fixes: { estimated: [], measured: [] },
    weeks_observed: input.weeksObserved,
    narrative: null,
    generated_at: new Date(input.now).toISOString(),
  };
}
