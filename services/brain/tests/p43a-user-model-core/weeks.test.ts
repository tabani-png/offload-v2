// Week records, month and quarter rollups, Theil-Sen and the narrative check (carried from old s36 weeks.test.ts).
import { describe, expect, test } from "bun:test";
import { isIsoWeek, isoWeekOf, weekDays, weekIndex } from "../../src/records/dates.ts";
import { collectFigures, figure } from "../../src/records/figure.ts";
import { checkNarrative, weekSentence, writeWeekSentence } from "../../src/records/narrative.ts";
import { buildRollup, theilSen } from "../../src/records/rollup.ts";
import { buildWeekRecord, type WeekRecord } from "../../src/records/week-record.ts";
import { liveWeeks } from "../fixtures/pipeline.ts";
import { WEEKS } from "../fixtures/window.ts";

const L = liveWeeks();
const week = (w: string) => L.weeks.get(w)!;
const task = (w: string, name: string) => week(w).tasks.find((t) => t.name === name)!;
const r1 = (x: number) => Math.round(x * 10) / 10;
const r2 = (x: number) => Math.round(x * 100) / 100;
const pts = (ys: number[]) => ys.map((y, x) => ({ x, y }));

describe("p43a week records", () => {
  test("WEEK: ISO week labels; a week's days are Monday..Sunday", () => {
    expect(isoWeekOf("2026-10-12")).toBe("2026-W42");
    expect(isoWeekOf("2026-10-18")).toBe("2026-W42");
    expect(isoWeekOf("2026-01-01")).toBe("2026-W01");
    expect(isoWeekOf("2027-01-01")).toBe("2026-W53");
    expect(isIsoWeek("2026-W53")).toBe(true);
    expect(isIsoWeek("2025-W53")).toBe(false);
    expect(weekDays("2026-W42")).toEqual(["2026-10-12", "2026-10-13", "2026-10-14", "2026-10-15", "2026-10-16", "2026-10-17", "2026-10-18"]);
  });

  test("WEEK: hours are the sum of the week's day records; every figure says how it was computed", () => {
    for (const w of WEEKS) {
      const r = week(w);
      const mins = weekDays(w).map((d) => L.days.get(d)?.totals.active_minutes.value ?? 0).reduce((a, b) => a + b, 0);
      expect(r.hours.total.value).toBe(r2(mins / 60));
      expect(r.hours.total.unit).toBe("hours");
      expect(r.hours.total.arithmetic.length).toBeGreaterThan(0);
      expect(r.hours.total.evidence).toEqual(weekDays(w).map((d) => ({ kind: "day_record", id: d })));
      expect(r.days_recorded.length).toBe(7);
      for (const t of r.tasks) expect(t.minutes.arithmetic.length).toBeGreaterThan(0);
    }
  });

  test("WEEK: tasks are new, recurring or gone; vsBaseline compares with the median of earlier weeks", () => {
    const o1 = task(WEEKS[0], "Outreach emails");
    expect(o1.status).toBe("new");
    expect(o1.vs_baseline).toBeNull();
    expect(o1.baseline_minutes).toBeNull();
    const o2 = task(WEEKS[1], "Outreach emails");
    expect(o2.status).toBe("recurring");
    expect(o2.baseline_minutes!.value).toBe(o1.minutes.value);
    expect(o2.vs_baseline!.value).toBe(r1((o2.minutes.value / o2.baseline_minutes!.value - 1) * 100));
    expect(o2.vs_baseline!.unit).toBe("percent");
    const o3 = task(WEEKS[2], "Outreach emails");
    expect(o3.baseline_minutes!.value).toBe(r1((o1.minutes.value + o2.minutes.value) / 2));
    const calls = task(WEEKS[2], "Calls in zoom");
    expect(calls.status).toBe("gone");
    expect(calls.minutes.value).toBe(0);
    expect(task(WEEKS[3], "Calls in zoom").status).toBe("recurring");
  });

  test("WEEK: the baseline uses the 8 calendar weeks before, and weeks_observed is not capped", () => {
    const w42 = week(WEEKS[0]);
    const withOutreach = (r: WeekRecord, isoWeek: string, minutes: number): WeekRecord => ({
      ...r, iso_week: isoWeek,
      tasks: r.tasks.map((t) => (t.name === "Outreach emails" ? { ...t, minutes: figure(minutes, "minutes", "test", []) } : t)),
    });
    const far = withOutreach(w42, "2026-W30", 999);
    const near = withOutreach(w42, "2026-W41", 100);
    const days = [...L.days.values()].filter((d) => isoWeekOf(d.day) === WEEKS[0]);
    const r = buildWeekRecord({ isoWeek: WEEKS[0], days, prior: [far, near], weeksObserved: 12, now: L.lastNow });
    const o = r.tasks.find((t) => t.name === "Outreach emails")!;
    expect(o.baseline_minutes!.value).toBe(100);
    expect(o.status).toBe("recurring");
    expect(r.weeks_observed).toBe(12);
    expect(week(WEEKS[3]).weeks_observed).toBe(4);
  });
});

describe("p43a rollups", () => {
  test("THEIL-SEN: median of pairwise slopes, robust to one odd week", () => {
    expect(theilSen(pts([1, 2, 3, 4]))).toBe(1);
    expect(theilSen(pts([10, 12, 100, 16]))).toBe(2);
    expect(theilSen(pts([5]))).toBeNull();
  });

  test("THEIL-SEN: a missing week keeps its place on the x axis", () => {
    expect(theilSen([{ x: 0, y: 10 }, { x: 1, y: 20 }, { x: 3, y: 40 }])).toBe(10);
    const weeks = [week(WEEKS[0]), week(WEEKS[1]), week(WEEKS[3])];
    const q = buildRollup("quarter", "2026-Q4", weeks, [], L.lastNow)!;
    const key = task(WEEKS[0], "Outreach emails").task_key;
    const series = weeks.map((r) => ({ x: weekIndex(r.iso_week), y: r.tasks.find((t) => t.task_key === key)!.minutes.value }));
    expect(q.trend.find((t) => t.task_key === key)!.slope_minutes_per_week.value).toBe(theilSen(series)!);
  });

  test("MONTH: the weeks whose Monday is in the month; persistent tasks; trend per task from the weekly minutes", () => {
    const all = [...L.weeks.values()];
    const m = buildRollup("month", "2026-10", all, ["email", "meetings"], L.lastNow)!;
    expect(m.weeks).toEqual(["2026-W42", "2026-W43", "2026-W44"]);
    const key = task(WEEKS[0], "Outreach emails").task_key;
    expect(m.persistent).toContain(key);
    expect(m.persistent).not.toContain(task(WEEKS[0], "Calls in zoom").task_key);
    const series = m.weeks.map((w) => ({ x: weekIndex(w), y: week(w).tasks.find((t) => t.task_key === key)?.minutes.value ?? 0 }));
    expect(m.trend.find((t) => t.task_key === key)!.slope_minutes_per_week.value).toBe(theilSen(series)!);
    expect(m.hours.total.value).toBe(r2(m.weeks.map((w) => week(w).hours.total.value).reduce((a, b) => a + b, 0)));
    expect(m.drift.drains.map((d) => d.drain)).toEqual(["email", "meetings"]);
    for (const d of m.drift.drains) expect(d.verdict).toBe(d.share.value >= 0.15 ? "confirmed" : "refuted");
  });

  test("MONTH: with one week there is no trend, and the record says so", () => {
    const m = buildRollup("month", "2026-11", [...L.weeks.values()], [], L.lastNow)!;
    expect(m.weeks).toEqual(["2026-W45"]);
    expect(m.trend).toEqual([]);
    expect(m.notes.join(" ")).toMatch(/at least 3 weeks/);
    expect(buildRollup("month", "2026-12", [...L.weeks.values()], [], L.lastNow)).toBeNull();
  });

  test("QUARTER: the four weeks of Q4 so far; persistence is 8 of 13 scaled to the weeks recorded", () => {
    const q = buildRollup("quarter", "2026-Q4", [...L.weeks.values()], [], L.lastNow)!;
    expect(q.weeks).toEqual([...WEEKS]);
    expect(q.persistent).toContain(task(WEEKS[0], "Calls in zoom").task_key);
  });

  test("NARRATIVE: a sentence whose numbers are all in the record passes; any other number is refused", () => {
    const m = buildRollup("month", "2026-10", [...L.weeks.values()], [], L.lastNow)!;
    expect(checkNarrative(`You worked ${m.hours.total.value} h over ${m.weeks.length} weeks.`, m).ok).toBe(true);
    const bad = checkNarrative("Outreach grew 999% since September.", m);
    expect(bad.ok).toBe(false);
    expect(bad.unknown).toContain("999");
  });

  test("NARRATIVE: digits inside task keys, figure ids and hashes are not known numbers", () => {
    const rec = { task_key: "k_9a9a9a9a9a9a", note: "fig_7777777777777777", minutes: figure(1200, "minutes", "sum of 3 days", [{ kind: "episode", id: "ep_i_20261012_5" }]) };
    expect(checkNarrative("It took 9 hours.", rec).ok).toBe(false);
    expect(checkNarrative("It took 7 hours.", rec).ok).toBe(false);
    expect(checkNarrative("It took 5 hours.", rec).ok).toBe(false);
    expect(checkNarrative("It took 1,200 minutes.", rec).ok).toBe(true);
    // A constant inside the arithmetic text is not a figure.
    expect(checkNarrative("It took 1,200 minutes over 3 days.", rec).ok).toBe(false);
  });

  test("NARRATIVE: dates, week numbers and constants in the arithmetic are not known numbers", () => {
    const r = week(WEEKS[3]);
    expect(checkNarrative(`You worked ${r.hours.total.value} h.`, r).ok).toBe(true);
    const values = new Set(collectFigures(r).map((f) => f.figure.value));
    for (const n of [60, 45, 2026, 100, 25]) {
      if (values.has(n)) continue;
      expect({ n, ok: checkNarrative(`You had ${n} calls.`, r).ok }).toEqual({ n, ok: false });
    }
  });

  test("NARRATIVE: a refused model sentence is replaced by the code sentence", async () => {
    const r = week(WEEKS[3]);
    const code = weekSentence(r);
    expect(checkNarrative(code, r).ok).toBe(true);
    expect(code).toContain(String(r.hours.total.value));
    const refused = await writeWeekSentence(r, undefined, async () => "You worked 999 hours this week.");
    expect(refused).toEqual({ sentence: code, source: "code" });
    const good = `A steady week: ${r.hours.total.value} h of active time.`;
    expect(await writeWeekSentence(r, undefined, async () => good)).toEqual({ sentence: good, source: "model" });
    expect(await writeWeekSentence(r, undefined, null)).toEqual({ sentence: code, source: "code" });
    expect(await writeWeekSentence(r, undefined, async () => { throw new Error("router down"); })).toEqual({ sentence: code, source: "code" });
  });
});
