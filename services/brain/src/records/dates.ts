// Calendar math. Days are in the member's timezone (Intl); ISO weeks, months and quarters are pure UTC calendar
// arithmetic on day labels, so the host timezone never matters (old bug: process-local Date math).
import type { DayLabel } from "../user-model/ports.ts";

export const DAY_RE = /^\d{4}-(0[1-9]|1[0-2])-(0[1-9]|[12]\d|3[01])$/;
export const WEEK_RE = /^(\d{4})-W(0[1-9]|[1-4]\d|5[0-3])$/;
export const MONTH_RE = /^(\d{4})-(0[1-9]|1[0-2])$/;
export const QUARTER_RE = /^(\d{4})-Q([1-4])$/;

export function isValidTimezone(_tz: string): boolean {
  throw new Error("not implemented");
}
/** The member-timezone day of an instant. */
export function dayOf(_ms: number, _timezone: string): DayLabel {
  throw new Error("not implemented");
}
/** A real calendar day in `YYYY-MM-DD`. */
export function isDay(_s: string): boolean {
  throw new Error("not implemented");
}
/** A real ISO week (week 53 only in years that have one). */
export function isIsoWeek(_s: string): boolean {
  throw new Error("not implemented");
}
export function addDays(_day: DayLabel, _n: number): DayLabel {
  throw new Error("not implemented");
}
export function isoWeekOf(_day: DayLabel): string {
  throw new Error("not implemented");
}
/** Monday..Sunday of an ISO week. */
export function weekDays(_isoWeek: string): DayLabel[] {
  throw new Error("not implemented");
}
export function addWeeks(_isoWeek: string, _n: number): string {
  throw new Error("not implemented");
}
/** Weeks since the ISO week of 1970-01-01: the x axis of trends. */
export function weekIndex(_isoWeek: string): number {
  throw new Error("not implemented");
}
/** `YYYY-MM` of the week's Monday. */
export function monthOfWeek(_isoWeek: string): string {
  throw new Error("not implemented");
}
/** `YYYY-Qn` of the week's Monday. */
export function quarterOfWeek(_isoWeek: string): string {
  throw new Error("not implemented");
}
