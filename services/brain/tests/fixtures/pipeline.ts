// Runs the pure p43a pipeline over several fixture weeks, the way the p43b job does with Postgres.
import type { DayRecord, Episode } from "../../src/records/day-record.ts";
import { isoWeekOf } from "../../src/records/dates.ts";
import { buildWeekRecord, type WeekRecord } from "../../src/records/week-record.ts";
import type { LedgerEntry } from "../../src/user-model/ledger.ts";
import type { Proposition } from "../../src/user-model/types.ts";
import { updateMemberModel } from "../../src/user-model/update.ts";
import { fixtureWeek, mondayNoonAfter, MONDAYS, SEED, type FixtureWeek, type WeekOptions } from "./window.ts";

export interface Lived {
  fixtures: FixtureWeek[];
  days: Map<string, DayRecord>;
  weeks: Map<string, WeekRecord>;
  episodes: Episode[];
  ledger: LedgerEntry[];
  propositions: Proposition[];
  /** Propositions after each week. */
  history: Proposition[][];
  keysByWeek: Array<Map<string, string>>;
  analysedDays: string[];
  lastNow: number;
}

/** Four weeks by default; week 3 (index 2) has no calls. */
export function liveWeeks(mondays: readonly string[] = MONDAYS, opts: (i: number) => WeekOptions = (i) => ({ seed: SEED + i, ...(i === 2 ? { without: ["calls"] } : {}) })): Lived {
  const out: Lived = { fixtures: [], days: new Map(), weeks: new Map(), episodes: [], ledger: [], propositions: [], history: [], keysByWeek: [], analysedDays: [], lastNow: 0 };
  mondays.forEach((monday, i) => {
    const fx = fixtureWeek(monday, opts(i));
    const now = mondayNoonAfter(monday);
    const u = updateMemberModel(fx.window, { ledger: out.ledger, propositions: out.propositions, analysedDays: out.analysedDays }, now);
    out.fixtures.push(fx);
    out.ledger = u.ledger;
    out.propositions = u.propositions;
    out.history.push(u.propositions);
    out.analysedDays = u.analysedDays;
    out.keysByWeek.push(u.keys);
    out.episodes.push(...u.episodes);
    for (const d of u.dayRecords) out.days.set(d.day, d);
    const week = isoWeekOf(monday);
    const days = [...out.days.values()].filter((d) => isoWeekOf(d.day) === week);
    out.weeks.set(week, buildWeekRecord({ isoWeek: week, days, prior: [...out.weeks.values()], weeksObserved: out.weeks.size + 1, now }));
    out.lastNow = now;
  });
  return out;
}
