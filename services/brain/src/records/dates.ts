// Calendar math. Days are in the member's timezone (Intl); ISO weeks, months and quarters are pure UTC calendar
// arithmetic on day labels, so the host timezone never matters (old bug: process-local Date math).
import type { DayLabel } from "../user-model/ports.ts";

export const DAY_RE = /^\d{4}-(0[1-9]|1[0-2])-(0[1-9]|[12]\d|3[01])$/;
export const WEEK_RE = /^(\d{4})-W(0[1-9]|[1-4]\d|5[0-3])$/;
export const MONTH_RE = /^(\d{4})-(0[1-9]|1[0-2])$/;
export const QUARTER_RE = /^(\d{4})-Q([1-4])$/;

const DAY_MS = 86_400_000;
const formatters = new Map<string, Intl.DateTimeFormat>();

function formatter(timezone: string): Intl.DateTimeFormat {
  let f = formatters.get(timezone);
  if (f === undefined) {
    f = new Intl.DateTimeFormat("en-CA", { timeZone: timezone, year: "numeric", month: "2-digit", day: "2-digit" });
    formatters.set(timezone, f);
  }
  return f;
}

export function isValidTimezone(tz: string): boolean {
  if (tz === "" || tz.length > 64) return false;
  try {
    formatter(tz);
    return true;
  } catch {
    // RangeError: not an IANA zone this runtime knows.
    return false;
  }
}

/** The member-timezone day of an instant. */
export function dayOf(ms: number, timezone: string): DayLabel {
  const parts = formatter(timezone).formatToParts(new Date(ms));
  const get = (t: string) => parts.find((p) => p.type === t)?.value ?? "";
  return `${get("year")}-${get("month")}-${get("day")}`;
}

const toUtc = (day: DayLabel): number => {
  const [y, m, d] = day.split("-").map(Number) as [number, number, number];
  return Date.UTC(y, m - 1, d);
};
const fromUtc = (ms: number): DayLabel => new Date(ms).toISOString().slice(0, 10);

/** A real calendar day in `YYYY-MM-DD`. */
export function isDay(s: string): boolean {
  return DAY_RE.test(s) && fromUtc(toUtc(s)) === s;
}

export function addDays(day: DayLabel, n: number): DayLabel {
  return fromUtc(toUtc(day) + n * DAY_MS);
}

export function isoWeekOf(day: DayLabel): string {
  const ms = toUtc(day);
  const dow = (new Date(ms).getUTCDay() + 6) % 7; // Monday = 0
  const thursday = ms + (3 - dow) * DAY_MS;
  const year = new Date(thursday).getUTCFullYear();
  const week = Math.floor((thursday - Date.UTC(year, 0, 1)) / DAY_MS / 7) + 1;
  return `${year}-W${String(week).padStart(2, "0")}`;
}

function mondayMs(isoWeek: string): number {
  const m = WEEK_RE.exec(isoWeek);
  if (m === null) throw new RangeError(`bad ISO week ${isoWeek}`);
  const jan4 = Date.UTC(Number(m[1]), 0, 4);
  const week1Monday = jan4 - ((new Date(jan4).getUTCDay() + 6) % 7) * DAY_MS;
  return week1Monday + (Number(m[2]) - 1) * 7 * DAY_MS;
}

/** A real ISO week (week 53 only in years that have one). */
export function isIsoWeek(s: string): boolean {
  return WEEK_RE.test(s) && isoWeekOf(fromUtc(mondayMs(s))) === s;
}

/** Monday..Sunday of an ISO week. */
export function weekDays(isoWeek: string): DayLabel[] {
  const monday = mondayMs(isoWeek);
  return Array.from({ length: 7 }, (_, i) => fromUtc(monday + i * DAY_MS));
}

export function addWeeks(isoWeek: string, n: number): string {
  return isoWeekOf(fromUtc(mondayMs(isoWeek) + n * 7 * DAY_MS));
}

/** Weeks since the ISO week of 1970-01-01 (Monday 1969-12-29): the x axis of trends. */
export function weekIndex(isoWeek: string): number {
  return Math.round((mondayMs(isoWeek) - Date.UTC(1969, 11, 29)) / (7 * DAY_MS));
}

/** `YYYY-MM` of the week's Monday. */
export function monthOfWeek(isoWeek: string): string {
  return fromUtc(mondayMs(isoWeek)).slice(0, 7);
}

/** `YYYY-Qn` of the week's Monday. */
export function quarterOfWeek(isoWeek: string): string {
  const month = monthOfWeek(isoWeek);
  return `${month.slice(0, 4)}-Q${Math.floor((Number(month.slice(5, 7)) - 1) / 3) + 1}`;
}
