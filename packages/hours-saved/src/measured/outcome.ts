// Fix outcomes: the measured saving after a fix ships (old brain/src/builder/outcomes.ts from PR #45, rewritten pure;
// ADR 0022). For the 4 weeks after shipping, each week's measured minutes for the task are recorded once, after the
// week ends, from that week's own stored days only, scaled × 7 / days stored when some days are missing (the 473cafb
// fix: the old route read the last 7 stored days, not the asked week). A week whose raw days were purged before it
// was measured says so and is never guessed. Saved per week = baseline − measured; the verdict compares the median
// saved minutes with the estimate. Numbers come from code with their arithmetic as Figures (ADR 0003). Thresholds are
// compared in integer tenths of a minute, so 80% is on_track however the floats fall.
import { figure, type Evidence, type Figure } from "./figure.ts";

export const WEEKS_TRACKED = 4;
export const ON_TRACK = 0.8;
export const PARTIAL = 0.5;
export const DAY_MS = 86_400_000;
export const WEEK_MS = 7 * DAY_MS;

export type OutcomeFlag = "pending" | "on_track" | "partial" | "under" | "unmeasured";

export class OutcomeError extends Error {}

export interface OutcomeWeek {
  week: number;
  start: number;
  end: number;
  measured_minutes: number | null;
  days_stored: number | null;
  source_purged: boolean;
  source_purged_at: number | null;
  measured_at: number | null;
  figure_id: string | null;
}

export interface ShipInput {
  routine_id: string;
  task_key: string;
  shipped_at: number;
  estimated_minutes_per_week: number;
  baseline_minutes_per_week: number;
}

/** The fix_outcomes row (DATA_MODEL section 7) plus its Figures. */
export interface FixOutcome extends ShipInput {
  weeks: OutcomeWeek[];
  flag: OutcomeFlag;
  ratio: number | null;
  median_saved_minutes: number | null;
  arithmetic: string;
  figures: Figure[];
}

const r1 = (n: number) => Math.round(n * 10) / 10;
const tenths = (n: number) => Math.round(n * 10);
const fmt = (n: number) => String(r1(n));
const iso = (ms: number | null) => (ms === null ? null : new Date(ms).toISOString());

export function recordShip(i: ShipInput): FixOutcome {
  for (const k of ["estimated_minutes_per_week", "baseline_minutes_per_week", "shipped_at"] as const) {
    if (typeof i[k] !== "number" || !Number.isFinite(i[k]) || i[k] < 0) throw new OutcomeError(`${k} must be a finite number ≥ 0`);
  }
  if (typeof i.routine_id !== "string" || i.routine_id === "") throw new OutcomeError("routine_id is required");
  if (typeof i.task_key !== "string" || i.task_key === "") throw new OutcomeError("task_key is required");
  const weeks: OutcomeWeek[] = Array.from({ length: WEEKS_TRACKED }, (_, n) => ({
    week: n + 1,
    start: i.shipped_at + n * WEEK_MS,
    end: i.shipped_at + (n + 1) * WEEK_MS,
    measured_minutes: null,
    days_stored: null,
    source_purged: false,
    source_purged_at: null,
    measured_at: null,
    figure_id: null,
  }));
  return refresh({ routine_id: i.routine_id, task_key: i.task_key, shipped_at: i.shipped_at, estimated_minutes_per_week: i.estimated_minutes_per_week, baseline_minutes_per_week: i.baseline_minutes_per_week, weeks, flag: "pending", ratio: null, median_saved_minutes: null, arithmetic: "", figures: [] });
}

/** Ship once: an existing outcome for the routine is never overwritten (473cafb: shipping twice wiped measured weeks). */
export function shipOnce(existing: FixOutcome | null, i: ShipInput): FixOutcome {
  if (existing !== null) throw new OutcomeError("this fix already shipped; its weeks are being measured");
  return recordShip(i);
}

/** Minutes of the stored days in [start, end) only, and how many there were; null when the week has none. */
export function weekMinutes(days: ReadonlyArray<{ day_start: number; minutes: number }>, start: number, end: number): { minutes: number; days_stored: number } | null {
  const own = days.filter((d) => d.day_start >= start && d.day_start < end && Number.isFinite(d.minutes) && d.minutes >= 0);
  if (own.length === 0) return null;
  return { minutes: own.reduce((t, d) => t + d.minutes, 0), days_stored: own.length };
}

export type WeekValue = number | null | "purged";

export function median(xs: readonly number[]): number | null {
  if (xs.length === 0) return null;
  const d = [...xs].sort((a, b) => a - b);
  const m = d.length >> 1;
  return d.length % 2 === 1 ? d[m]! : (d[m - 1]! + d[m]!) / 2;
}

export function summarize(i: { estimated_minutes_per_week: number; baseline_minutes_per_week: number; weeks: readonly WeekValue[] }) {
  const got = i.weeks.filter((w): w is number => typeof w === "number");
  const saved_per_week = got.map((m) => r1(i.baseline_minutes_per_week - m));
  const med = median(saved_per_week);
  const median_saved_minutes = med === null ? null : r1(med);
  const complete = i.weeks.length === WEEKS_TRACKED && i.weeks.every((w) => w !== null);
  const e10 = tenths(i.estimated_minutes_per_week);
  const m10 = median_saved_minutes === null ? null : tenths(median_saved_minutes);
  const ratio = m10 === null || e10 <= 0 ? null : m10 / e10;
  let flag: OutcomeFlag;
  if (!complete) flag = "pending";
  else if (m10 === null || e10 <= 0) flag = "unmeasured";
  else if (m10 * 10 >= e10 * 8) flag = "on_track";
  else if (m10 * 10 >= e10 * 5) flag = "partial";
  else flag = "under";
  const shown = i.weeks.map((w) => (w === "purged" ? "purged" : w === null ? "not yet" : fmt(w))).join(", ");
  const percent = m10 === null || e10 <= 0 ? null : Math.round((m10 * 100) / e10);
  const arithmetic =
    median_saved_minutes === null
      ? `baseline ${fmt(i.baseline_minutes_per_week)} min/wk; no week measured yet (${shown}); estimated ${fmt(i.estimated_minutes_per_week)}`
      : `baseline ${fmt(i.baseline_minutes_per_week)} min/wk − measured ${shown} = saved ${saved_per_week.join(", ")}; median ${fmt(median_saved_minutes)} vs estimated ${fmt(i.estimated_minutes_per_week)}${percent === null ? "" : ` = ${percent}%`}`;
  return { saved_per_week, median_saved_minutes, ratio, percent, flag, arithmetic };
}

function refresh(o: FixOutcome): FixOutcome {
  const values: WeekValue[] = o.weeks.map((w) => (w.source_purged ? "purged" : w.measured_minutes));
  const s = summarize({ estimated_minutes_per_week: o.estimated_minutes_per_week, baseline_minutes_per_week: o.baseline_minutes_per_week, weeks: values });
  const figures: Figure[] = [];
  const weekRef = (w: OutcomeWeek): Evidence => ({ kind: "fix_outcome_week", id: `${o.routine_id}:w${w.week}` });
  const weeks = o.weeks.map((w) => {
    let f: Figure | null = null;
    if (w.source_purged) f = figure({ value: null, unit: "minutes_per_week", arithmetic: `week ${w.week}: its raw days were purged before it was measured; not guessed`, evidence: [weekRef(w)], source_purged_at: iso(w.source_purged_at) });
    else if (w.measured_minutes !== null && w.days_stored !== null) {
      const raw = r1((w.measured_minutes * w.days_stored) / 7);
      const arithmetic = w.days_stored === 7 ? `${fmt(w.measured_minutes)} min over 7 stored days = ${fmt(w.measured_minutes)} min/wk` : `${fmt(raw)} min over ${w.days_stored} stored ${w.days_stored === 1 ? "day" : "days"} × 7 / ${w.days_stored} = ${fmt(w.measured_minutes)} min/wk`;
      f = figure({ value: w.measured_minutes, unit: "minutes_per_week", arithmetic, evidence: [weekRef(w)], source_purged_at: null });
    }
    if (f !== null) figures.push(f);
    return { ...w, figure_id: f?.id ?? null };
  });
  const purgedAt = weeks.reduce<number | null>((m, w) => (w.source_purged_at !== null && (m === null || w.source_purged_at > m) ? w.source_purged_at : m), null);
  const done = weeks.filter((w) => w.source_purged || w.measured_minutes !== null).map(weekRef);
  if (s.median_saved_minutes !== null) {
    figures.push(figure({ value: s.median_saved_minutes, unit: "minutes_per_week", arithmetic: `median saved ${fmt(s.median_saved_minutes)} min/wk = median of ${s.saved_per_week.join(", ")} (baseline ${fmt(o.baseline_minutes_per_week)} min/wk − each measured week)`, evidence: done, source_purged_at: iso(purgedAt) }));
    if (s.percent !== null) {
      figures.push(figure({ value: s.percent, unit: "percent", arithmetic: `${fmt(s.median_saved_minutes)} saved ÷ ${fmt(o.estimated_minutes_per_week)} estimated = ${s.percent}%`, evidence: [{ kind: "fix_outcome", id: o.routine_id }, ...done], source_purged_at: iso(purgedAt) }));
    }
  }
  return { ...o, weeks, flag: s.flag, ratio: s.ratio, median_saved_minutes: s.median_saved_minutes, arithmetic: s.arithmetic, figures };
}

/** Measures every ended, unmeasured week of a copy of `o`. `measureWeek` returns the task's minutes over that week's own
 * stored days and how many days were stored (see weekMinutes), or null when it cannot tell yet. A week whose first
 * day is older than the raw TTL is source purged and never asked. `o` itself is not changed. */
export async function measureDue(
  o: FixOutcome,
  i: { now: number; raw_ttl_days: number; measureWeek: (task_key: string, start: number, end: number) => Promise<{ minutes: number; days_stored: number } | null> },
): Promise<FixOutcome> {
  const next: FixOutcome = structuredClone(o);
  for (const w of next.weeks) {
    if (w.end > i.now || w.measured_minutes !== null || w.source_purged) continue;
    const purgeAt = w.start + i.raw_ttl_days * DAY_MS;
    if (i.now > purgeAt) {
      w.source_purged = true;
      w.source_purged_at = purgeAt;
      continue;
    }
    const m = await i.measureWeek(next.task_key, w.start, w.end);
    if (m === null || typeof m.minutes !== "number" || !Number.isFinite(m.minutes) || m.minutes < 0) continue;
    if (!Number.isInteger(m.days_stored) || m.days_stored < 1 || m.days_stored > 7) continue;
    w.measured_minutes = r1((m.minutes * 7) / m.days_stored);
    w.days_stored = m.days_stored;
    w.measured_at = i.now;
  }
  return refresh(next);
}

/** For the month record: each fix whose 4-week window ended in [start, end). */
export function monthOutcomes(outcomes: readonly FixOutcome[], start: number, end: number) {
  return outcomes
    .filter((o) => {
      const e = o.weeks.at(-1)!.end;
      return e >= start && e < end;
    })
    .map((o) => ({ routine_id: o.routine_id, task_key: o.task_key, shipped_at: o.shipped_at, window_end: o.weeks.at(-1)!.end, flag: o.flag, estimated_minutes_per_week: o.estimated_minutes_per_week, median_saved_minutes: o.median_saved_minutes, ratio: o.ratio, arithmetic: o.arithmetic, figures: o.figures }));
}
