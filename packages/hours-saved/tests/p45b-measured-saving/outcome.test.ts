// p45b (old brain/tests/s35-build-loop/outcomes.test.ts + the per-week measurement of routes-hardening.test.ts):
// four weekly windows after a fix ships; ended weeks measured once, from their own stored days only, partial weeks
// scaled × 7 / days stored; purged weeks say so and are never guessed; after 4 weeks the median measured saving is
// compared with the estimate, with the arithmetic as Figures (ADR 0003, ADR 0022). Pure functions, no I/O.
import { describe, expect, test } from "bun:test";
import { createHash } from "node:crypto";
import {
  DAY_MS,
  measureDue,
  monthOutcomes,
  ON_TRACK,
  OutcomeError,
  PARTIAL,
  recordShip,
  shipOnce,
  summarize,
  weekMinutes,
  WEEKS_TRACKED,
  type FixOutcome,
} from "../../src/measured/index.ts";

const T0 = Date.UTC(2026, 10, 2, 9);
const SHIP = { routine_id: "0193a6f2-0000-7000-8000-0000000000r1", task_key: "k_0123456789ab", shipped_at: T0, estimated_minutes_per_week: 90, baseline_minutes_per_week: 120 };
const ship = (over: Partial<typeof SHIP> = {}) => recordShip({ ...SHIP, ...over });
const TTL = 30;
const measureAll = async (o: FixOutcome, now: number, m: (start: number, end: number) => { minutes: number; days_stored: number } | null) =>
  measureDue(o, { now, raw_ttl_days: TTL, measureWeek: async (_k, s, e) => m(s, e) });

describe("p45b measured saving", () => {
  test("SHIP: records the estimate, the baseline and four empty weekly windows", () => {
    const o = ship();
    expect(WEEKS_TRACKED).toBe(4);
    expect(o.weeks.map((w) => [w.week, w.start - T0, w.end - T0])).toEqual([1, 2, 3, 4].map((n) => [n, (n - 1) * 7 * DAY_MS, n * 7 * DAY_MS]));
    expect(o.weeks.every((w) => w.measured_minutes === null && !w.source_purged && w.measured_at === null)).toBe(true);
    expect(o).toMatchObject({ estimated_minutes_per_week: 90, baseline_minutes_per_week: 120, flag: "pending", ratio: null });
  });

  test("SHIP: estimates must be finite, non-negative minutes", () => {
    for (const bad of [{ estimated_minutes_per_week: Number.NaN }, { baseline_minutes_per_week: -1 }, { shipped_at: Number.POSITIVE_INFINITY }, { routine_id: "" }, { task_key: "" }]) {
      expect(() => ship(bad)).toThrow(OutcomeError);
    }
  });

  test("SHIP: shipping the same routine twice is refused; the first outcome and its weeks are kept", async () => {
    const first = await measureAll(ship(), T0 + 7 * DAY_MS + 1, () => ({ minutes: 40, days_stored: 7 }));
    const before = JSON.stringify(first);
    expect(() => shipOnce(first, { ...SHIP, shipped_at: T0 + 8 * DAY_MS, baseline_minutes_per_week: 50 })).toThrow(OutcomeError);
    expect(JSON.stringify(first)).toBe(before);
    expect(shipOnce(null, SHIP).weeks).toHaveLength(4);
  });

  test("MEASURE: only weeks that have ended are measured, each once, at its own end", async () => {
    const asked: number[] = [];
    const m = (s: number, e: number) => (asked.push(e), { minutes: 40, days_stored: 7 });
    let o = await measureAll(ship(), T0 + 6 * DAY_MS, m);
    expect(asked).toEqual([]);
    o = await measureAll(o, T0 + 7 * DAY_MS + 3_600_000, m);
    o = await measureAll(o, T0 + 7 * DAY_MS + 7_200_000, m);
    o = await measureAll(o, T0 + 14 * DAY_MS + 3_600_000, m);
    expect(asked).toEqual([T0 + 7 * DAY_MS, T0 + 14 * DAY_MS]);
    expect(o.weeks.map((w) => w.measured_minutes)).toEqual([40, 40, null, null]);
    expect(o.weeks[0]!.measured_at).toBe(T0 + 7 * DAY_MS + 3_600_000);
    expect(o.flag).toBe("pending");
  });

  test("MEASURE: a week whose raw days were purged before it was measured says so and is never guessed", async () => {
    let n = 0;
    const o = await measureAll(ship(), T0 + (TTL + 1) * DAY_MS, () => (n++, { minutes: 10, days_stored: 7 }));
    expect(o.weeks[0]).toMatchObject({ measured_minutes: null, source_purged: true, source_purged_at: T0 + TTL * DAY_MS });
    expect(o.weeks[1]!.source_purged).toBe(false);
    expect(n).toBe(3); // weeks 2 to 4 were still inside the raw TTL
  });

  test("MEASURE: a week is measured from its own stored days only; a week with none is not measured", () => {
    const start = T0;
    const end = T0 + 7 * DAY_MS;
    const days = [
      { day_start: start - DAY_MS, minutes: 500 }, // the day before: another week
      { day_start: start, minutes: 10 },
      { day_start: start + 3 * DAY_MS, minutes: 20 },
      { day_start: end, minutes: 900 }, // the next week's first day
    ];
    expect(weekMinutes(days, start, end)).toEqual({ minutes: 30, days_stored: 2 });
    expect(weekMinutes(days, end + 7 * DAY_MS, end + 14 * DAY_MS)).toBeNull();
  });

  test("MEASURE: a week with only some stored days is scaled to a week (× 7 / days stored)", async () => {
    const o = await measureAll(ship(), T0 + 7 * DAY_MS + 1, () => ({ minutes: 20, days_stored: 4 }));
    expect(o.weeks[0]).toMatchObject({ measured_minutes: 35, days_stored: 4 });
    const fig = o.figures.find((f) => f.id === o.weeks[0]!.figure_id)!;
    expect(fig.arithmetic).toBe("20 min over 4 stored days × 7 / 4 = 35 min/wk");
  });

  test("MEASURE: a week that cannot be measured yet is asked again later, and stays pending until measured or purged", async () => {
    let o = await measureAll(ship(), T0 + 7 * DAY_MS + 1, () => null);
    expect(o.weeks[0]!.measured_minutes).toBeNull();
    expect(o.weeks[0]!.source_purged).toBe(false);
    for (const bad of [{ minutes: -1, days_stored: 3 }, { minutes: 5, days_stored: 0 }, { minutes: 5, days_stored: 8 }, { minutes: Number.NaN, days_stored: 1 }]) {
      o = await measureAll(o, T0 + 7 * DAY_MS + 2, () => bad);
      expect(o.weeks[0]!.measured_minutes).toBeNull();
    }
    o = await measureAll(o, T0 + 7 * DAY_MS + 3, () => ({ minutes: 50, days_stored: 7 }));
    expect(o.weeks[0]!.measured_minutes).toBe(50);
  });

  test("MEASURE: measureDue never changes the outcome it is given", async () => {
    const o = ship();
    const before = JSON.stringify(o);
    await measureAll(o, T0 + 30 * DAY_MS, () => ({ minutes: 40, days_stored: 7 }));
    expect(JSON.stringify(o)).toBe(before);
  });

  test("FLAG: after 4 weeks the median measured saving is compared with the estimate, with the arithmetic", () => {
    const s = summarize({ ...SHIP, weeks: [40, 35, 50, 45] });
    expect(s.saved_per_week).toEqual([80, 85, 70, 75]);
    expect(s.median_saved_minutes).toBe(77.5);
    expect(s.ratio).toBeCloseTo(0.861, 3);
    expect(s.flag).toBe("on_track");
    expect(s.arithmetic).toBe("baseline 120 min/wk − measured 40, 35, 50, 45 = saved 80, 85, 70, 75; median 77.5 vs estimated 90 = 86%");
    expect(summarize({ ...SHIP, weeks: [70, 60, 65, 66] }).flag).toBe("partial");
    expect(summarize({ ...SHIP, weeks: [110, 125, 118, 121] }).flag).toBe("under");
  });

  test("FLAG: pending until all four weeks are measured or purged; unmeasured when none could be", () => {
    expect(summarize({ ...SHIP, weeks: [40, null, null, null] }).flag).toBe("pending");
    expect(summarize({ ...SHIP, weeks: ["purged", "purged", "purged", "purged"] }).flag).toBe("unmeasured");
    expect(summarize({ ...SHIP, weeks: ["purged", 40, "purged", 50] })).toMatchObject({ flag: "on_track", median_saved_minutes: 75 });
    expect(summarize({ ...SHIP, estimated_minutes_per_week: 0, weeks: [40, 40, 40, 40] }).flag).toBe("unmeasured");
    expect(summarize({ ...SHIP, weeks: ["purged", 40, null, 50] }).arithmetic).toContain("purged, 40, not yet, 50");
  });

  test("OUTCOME: median saved 80% of the estimate is on_track; 50% is partial; 49% is under", () => {
    expect([ON_TRACK, PARTIAL]).toEqual([0.8, 0.5]);
    // estimate 90: saved 72 = 80%, 45 = 50%, 44.1 = 49%; baseline 120 minus those
    expect(summarize({ ...SHIP, weeks: [48, 48, 48, 48] }).flag).toBe("on_track");
    expect(summarize({ ...SHIP, weeks: [48.1, 48.1, 48.1, 48.1] }).flag).toBe("partial");
    expect(summarize({ ...SHIP, weeks: [75, 75, 75, 75] }).flag).toBe("partial");
    expect(summarize({ ...SHIP, weeks: [75.9, 75.9, 75.9, 75.9] }).flag).toBe("under");
    // float edge: 2.8 / 3.5 is 0.7999999999999999 in floating point, but saved 2.8 of 3.5 is exactly 80%
    expect(summarize({ ...SHIP, estimated_minutes_per_week: 3.5, baseline_minutes_per_week: 4, weeks: [1.2, 1.2, 1.2, 1.2] }).flag).toBe("on_track");
  });

  test("MONTH: the month record gets each fix whose 4 weeks ended in it, flag and arithmetic included", async () => {
    let o = ship();
    for (const d of [7, 14, 21, 28]) o = await measureAll(o, T0 + d * DAY_MS + 3_600_000, () => ({ minutes: 40, days_stored: 7 }));
    const nov = monthOutcomes([o, ship({ routine_id: "r2", shipped_at: T0 + 20 * DAY_MS })], Date.UTC(2026, 10, 1), Date.UTC(2026, 11, 1));
    expect(nov).toHaveLength(1);
    expect(nov[0]).toMatchObject({ routine_id: SHIP.routine_id, task_key: SHIP.task_key, flag: "on_track", estimated_minutes_per_week: 90, median_saved_minutes: 80 });
    expect(nov[0]!.arithmetic).toContain("estimated 90");
    expect(monthOutcomes([o], Date.UTC(2026, 11, 1), Date.UTC(2027, 0, 1))).toHaveLength(0);
  });

  test("FIGURE: every number is a Figure with arithmetic, evidence and a stable fig_ id", async () => {
    let o = ship();
    for (const d of [7, 14, 21, 28]) o = await measureAll(o, T0 + d * DAY_MS + 1, () => ({ minutes: 40, days_stored: 7 }));
    expect(o.figures.length).toBe(6); // 4 weeks, median saved, ratio
    for (const f of o.figures) {
      expect(Object.keys(f).sort()).toEqual(["arithmetic", "evidence", "id", "source_purged_at", "unit", "value"]);
      expect(f.arithmetic.length).toBeGreaterThan(0);
      expect(f.evidence.length).toBeGreaterThan(0);
      const { id, ...rest } = f;
      const jcs = (v: unknown): string => (Array.isArray(v) ? `[${v.map(jcs).join(",")}]` : v !== null && typeof v === "object" ? `{${Object.keys(v).sort().map((k) => `${JSON.stringify(k)}:${jcs((v as Record<string, unknown>)[k])}`).join(",")}}` : JSON.stringify(v));
      expect(id).toBe(`fig_${createHash("sha256").update(jcs(rest)).digest("hex").slice(0, 16)}`);
    }
    const median = o.figures.find((f) => f.unit === "minutes_per_week" && f.arithmetic.startsWith("median"))!;
    expect(median.value).toBe(80);
    expect(median.evidence.map((e) => e.id)).toEqual([1, 2, 3, 4].map((n) => `${SHIP.routine_id}:w${n}`));
    const ratio = o.figures.find((f) => f.unit === "percent")!;
    expect(ratio.value).toBe(89);
  });

  test("FIGURE: a purged week's figure keeps source_purged_at and the median says the source was purged", async () => {
    let o = await measureAll(ship(), T0 + (TTL + 1) * DAY_MS, () => ({ minutes: 40, days_stored: 7 }));
    o = await measureAll(o, T0 + 60 * DAY_MS, () => ({ minutes: 40, days_stored: 7 }));
    const w1 = o.figures.find((f) => f.id === o.weeks[0]!.figure_id)!;
    expect(w1).toMatchObject({ value: null, source_purged_at: new Date(T0 + TTL * DAY_MS).toISOString() });
    const median = o.figures.find((f) => f.arithmetic.startsWith("median"))!;
    expect(median.source_purged_at).toBe(new Date(T0 + TTL * DAY_MS).toISOString());
    expect(o.flag).toBe("on_track");
  });
});
