// Month and quarter records: rollups of week records (old week-record.ts rollups). Trend = Theil-Sen slope of weekly
// minutes over (week index, minutes) points, so a missing week keeps its place on the x axis (old bug: absent weeks
// were dropped and the rest treated as consecutive).
import { DRAIN_KINDS } from "./kinds.ts";
import { MONTH_RE, QUARTER_RE, monthOfWeek, quarterOfWeek, weekIndex } from "./dates.ts";
import { figure, r1, r2, r3, type EvidenceRef, type Figure } from "./figure.ts";
import type { WeekRecord } from "./week-record.ts";
import { median } from "../user-model/observe.ts";

export const MIN_TREND_WEEKS = 3;
export const MONTH_PERSISTENCE = 0.75;
export const QUARTER_PERSISTENCE = 8 / 13;
/** A drain is confirmed when its kinds of work take at least this share of the period's hours. */
export const DRAIN_CONFIRM_SHARE = 0.15;

export interface RollupRecord {
  kind: "month" | "quarter";
  /** `YYYY-MM` or `YYYY-Qn`. */
  period: string;
  weeks: string[];
  hours: { total: Figure };
  by_task: Array<{ task_key: string; name: string; minutes: Figure; weeks_present: Figure }>;
  persistent: string[];
  trend: Array<{ task_key: string; name: string; slope_minutes_per_week: Figure }>;
  drift: { drains: Array<{ drain: string; verdict: "confirmed" | "refuted"; share: Figure }> };
  notes: string[];
  narrative: string | null;
  generated_at: string;
}

/** Theil-Sen slope: the median of all pairwise slopes, rounded to 0.1. null with fewer than 2 points. */
export function theilSen(points: ReadonlyArray<{ x: number; y: number }>): number | null {
  const slopes: number[] = [];
  for (let i = 0; i < points.length; i++) {
    for (let j = i + 1; j < points.length; j++) {
      const dx = points[j]!.x - points[i]!.x;
      if (dx !== 0) slopes.push((points[j]!.y - points[i]!.y) / dx);
    }
  }
  return slopes.length === 0 ? null : r1(median(slopes));
}

/** Month or quarter record from the week records available (others are ignored). null when no week is in it. */
export function buildRollup(kind: "month" | "quarter", period: string, weeks: readonly WeekRecord[], drains: readonly string[], now: number): RollupRecord | null {
  if (!(kind === "month" ? MONTH_RE : QUARTER_RE).test(period)) throw new RangeError(`bad ${kind} ${period}`);
  const inPeriod = (w: string) => (kind === "month" ? monthOfWeek(w) : quarterOfWeek(w)) === period;
  const recs = [...new Map(weeks.filter((w) => inPeriod(w.iso_week)).map((w) => [w.iso_week, w])).values()].sort((a, b) => (a.iso_week < b.iso_week ? -1 : 1));
  if (recs.length === 0) return null;
  const n = recs.length;
  const refs: EvidenceRef[] = recs.map((w) => ({ kind: "week_record", id: w.iso_week }));
  const notes: string[] = [];
  const total = r2(recs.reduce((s, w) => s + w.hours.total.value, 0));

  const tasks = new Map<string, { name: string; minutes: number; weeks: string[] }>();
  for (const w of recs) for (const t of w.tasks) {
    if (t.minutes.value <= 0) continue;
    const x = tasks.get(t.task_key) ?? { name: t.name, minutes: 0, weeks: [] };
    x.minutes += t.minutes.value;
    x.weeks.push(w.iso_week);
    tasks.set(t.task_key, x);
  }
  const threshold = kind === "month" ? MONTH_PERSISTENCE : QUARTER_PERSISTENCE;
  const need = Math.ceil(threshold * n);
  const persistent = n < 2 ? [] : [...tasks].filter(([, x]) => x.weeks.length >= need).map(([k]) => k).sort();
  if (n < 2) notes.push("persistence needs at least 2 weeks");

  const trend: RollupRecord["trend"] = [];
  if (n >= MIN_TREND_WEEKS) {
    for (const [key, x] of tasks) {
      const points = recs.map((w) => ({ x: weekIndex(w.iso_week), y: w.tasks.find((t) => t.task_key === key)?.minutes.value ?? 0 }));
      const slope = theilSen(points)!;
      trend.push({ task_key: key, name: x.name, slope_minutes_per_week: figure(slope, "minutes_per_week", `Theil-Sen slope (median of pairwise slopes) of weekly minutes over ${n} weeks = ${slope} min per week`, refs) });
    }
    trend.sort((a, b) => Math.abs(b.slope_minutes_per_week.value) - Math.abs(a.slope_minutes_per_week.value) || (a.task_key < b.task_key ? -1 : 1));
  } else notes.push(`trend needs at least ${MIN_TREND_WEEKS} weeks (have ${n})`);

  const kindHours = new Map<string, number>();
  for (const w of recs) for (const k of w.hours.by_kind) kindHours.set(k.kind, (kindHours.get(k.kind) ?? 0) + k.hours.value);
  const driftDrains: RollupRecord["drift"]["drains"] = [];
  for (const d of drains) {
    const kinds = DRAIN_KINDS[d as keyof typeof DRAIN_KINDS] ?? [];
    if (kinds.length === 0) continue;
    const h = kinds.reduce((s, k) => s + (kindHours.get(k) ?? 0), 0);
    const share = total === 0 ? 0 : r3(h / total);
    driftDrains.push({ drain: d, verdict: share >= DRAIN_CONFIRM_SHARE ? "confirmed" : "refuted", share: figure(share, "ratio", `${r2(h)} h of ${kinds.join(", ")} work / ${total} h = ${share}`, refs) });
  }

  return {
    kind, period, weeks: recs.map((w) => w.iso_week),
    hours: { total: figure(total, "hours", `sum of ${n} week records' hours = ${total} h`, refs) },
    by_task: [...tasks].map(([task_key, x]) => ({
      task_key, name: x.name,
      minutes: figure(r1(x.minutes), "minutes", `sum of the task's minutes in ${x.weeks.length} weeks = ${r1(x.minutes)} min`, x.weeks.map((id) => ({ kind: "week_record" as const, id }))),
      weeks_present: figure(x.weeks.length, "weeks", `present in ${x.weeks.length} of ${n} recorded weeks`, x.weeks.map((id) => ({ kind: "week_record" as const, id }))),
    })).sort((a, b) => b.minutes.value - a.minutes.value || (a.task_key < b.task_key ? -1 : 1)),
    persistent, trend, drift: { drains: driftDrains }, notes, narrative: null, generated_at: new Date(now).toISOString(),
  };
}
