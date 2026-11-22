// Task evidence for the fix rules (slice m5-04, SPEC Design note 1). Pure: the job reads the episodes (through
// day_records.episode_ids) and the week record; this counts. Bundle ids, bare hosts, counts and episode ids only.
import type { Episode } from "../records/day-record.ts";
import { addWeeks, isoWeekOf, weekDays } from "../records/dates.ts";
import { isBrowser, kindOf } from "../records/kinds.ts";
import type { WeekRecord } from "../records/week-record.ts";
import { isStandInApp } from "../understanding/cues.ts";
import type { Cadence, System, TaskEvidence } from "./types.ts";

/** Weeks of history a weekly cadence looks at (as the score's persistence). */
export const CADENCE_WEEKS = 8;
/** At least this many days, one instance each, make a daily cadence. */
export const DAILY_MIN_DAYS = 3;
/** Start times of a cadence fall within this many minutes of each other. */
export const CADENCE_BAND_MINUTES = 120;

export interface EvidenceInput {
  week: WeekRecord;
  /** Task-instance episodes of the last 8 weeks up to this one, read through day_records.episode_ids. */
  episodes: readonly Episode[];
  timezone: string;
}

const clock = new Map<string, Intl.DateTimeFormat>();
/** Minutes after local midnight and weekday (0 = Monday) of an instant in `timezone`. */
function localTime(iso: string, timezone: string): { minutes: number; weekday: number } {
  let f = clock.get(timezone);
  if (f === undefined) {
    f = new Intl.DateTimeFormat("en-US", { timeZone: timezone, hourCycle: "h23", hour: "2-digit", minute: "2-digit", weekday: "short" });
    clock.set(timezone, f);
  }
  const parts = f.formatToParts(new Date(iso));
  const get = (t: string) => parts.find((p) => p.type === t)?.value ?? "";
  const weekday = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"].indexOf(get("weekday"));
  return { minutes: Number(get("hour")) * 60 + Number(get("minute")), weekday };
}

const median = (xs: readonly number[]): number => {
  const s = [...xs].sort((a, b) => a - b);
  const m = Math.floor(s.length / 2);
  return s.length % 2 === 1 ? s[m]! : (s[m - 1]! + s[m]!) / 2;
};
const banded = (mins: readonly number[]) => Math.max(...mins) - Math.min(...mins) <= CADENCE_BAND_MINUTES;
const hourOf = (mins: readonly number[]) => Math.floor(median(mins) / 60);

function cadenceOf(history: readonly Episode[], thisWeek: readonly Episode[], timezone: string): Cadence | null {
  const t = thisWeek.map((e) => localTime(e.started_at, timezone).minutes);
  if (thisWeek.length >= DAILY_MIN_DAYS && new Set(thisWeek.map((e) => e.day)).size === thisWeek.length && banded(t)) {
    return { kind: "daily", weekday: null, hour: hourOf(t) };
  }
  const byWeek = new Map<string, Episode[]>();
  for (const e of history) byWeek.set(isoWeekOf(e.day), [...(byWeek.get(isoWeekOf(e.day)) ?? []), e]);
  if (byWeek.size < 2 || [...byWeek.values()].some((es) => es.length !== 1)) return null;
  const times = [...byWeek.values()].map((es) => localTime(es[0]!.started_at, timezone));
  const weekday = times[0]!.weekday;
  if (times.some((x) => x.weekday !== weekday) || !banded(times.map((x) => x.minutes))) return null;
  return { kind: "weekly", weekday, hour: hourOf(times.map((x) => x.minutes)) };
}

function systemsOf(episodes: readonly Episode[]): System[] {
  const out = new Map<string, System>();
  for (const e of episodes) {
    for (const host of e.hosts ?? []) if (host !== "") out.set(host, { id: host, surface: "web", work_kind: kindOf({ appBundleId: "", host }) });
    for (const app of e.apps) {
      // A browser is a vehicle (its hosts name the work); a stand-in app says nothing about the work.
      if (isBrowser(app) || isStandInApp(app, "Screen")) continue;
      out.set(app, { id: app, surface: "desktop", work_kind: kindOf({ appBundleId: app, host: "" }) });
    }
  }
  return [...out.values()].sort((a, b) => (a.id < b.id ? -1 : a.id > b.id ? 1 : 0));
}

/** One evidence per task of the week record, in the record's order. */
export function buildTaskEvidence(input: EvidenceInput): TaskEvidence[] {
  const { week, timezone } = input;
  const days = new Set(weekDays(week.iso_week));
  const oldest = addWeeks(week.iso_week, -(CADENCE_WEEKS - 1));
  const instances = input.episodes
    .filter((e) => e.kind === "task_instance" && e.task_key !== null && isoWeekOf(e.day) >= oldest && isoWeekOf(e.day) <= week.iso_week)
    .sort((a, b) => (a.started_at < b.started_at ? -1 : a.started_at > b.started_at ? 1 : a.id < b.id ? -1 : 1));
  return week.tasks.map((t): TaskEvidence => {
    const history = instances.filter((e) => e.task_key === t.task_key);
    const thisWeek = history.filter((e) => days.has(e.day));
    return {
      task_key: t.task_key, name: t.name, iso_week: week.iso_week,
      minutes: t.minutes.value, instances: t.instances.value, median_minutes: t.median_minutes.value,
      days: new Set(thisWeek.map((e) => e.day)).size,
      systems: systemsOf(thisWeek),
      cadence: thisWeek.length === 0 ? null : cadenceOf(history, thisWeek, timezone),
      episode_ids: thisWeek.map((e) => e.id).sort(),
    };
  });
}
