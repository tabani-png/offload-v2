// Day records, episodes and observations (carried from old s36 dayrecord.test.ts and model.test.ts OBSERVE).
import { describe, expect, test } from "bun:test";
import { createHash } from "node:crypto";
import { buildDayRecords } from "../../src/records/day-record.ts";
import { dayOf } from "../../src/records/dates.ts";
import { collectFigures, type Figure } from "../../src/records/figure.ts";
import { jcs } from "../../src/records/jcs.ts";
import { resolveTaskKeys } from "../../src/user-model/ledger.ts";
import { hasLeak, safeName } from "../../src/user-model/names.ts";
import { observeWindow } from "../../src/user-model/observe.ts";
import type { UnderstandingWindow } from "../../src/user-model/ports.ts";
import { fixtureWeek, mondayNoonAfter, MONDAYS } from "../fixtures/window.ts";

const fx = fixtureWeek(MONDAYS[0]);
const w = fx.window;
const keys = resolveTaskKeys([], w).keys;
const NOW = mondayNoonAfter(MONDAYS[0]);
const r1 = (x: number) => Math.round(x * 10) / 10;

/** Independent canonical form for the figure check: sorted keys, JSON.stringify for leaves. */
function canon(v: unknown): string {
  if (Array.isArray(v)) return `[${v.map(canon).join(",")}]`;
  if (v !== null && typeof v === "object") {
    const o = v as Record<string, unknown>;
    return `{${Object.keys(o).sort().map((k) => `${JSON.stringify(k)}:${canon(o[k])}`).join(",")}}`;
  }
  return JSON.stringify(v);
}

describe("p43a observations", () => {
  test("OBSERVE: one task observation per task; per-day counts add up to the task's instances", () => {
    const obs = observeWindow(w, keys);
    expect(obs.length).toBe(w.tasks.length);
    for (const t of w.tasks) {
      const o = obs.find((x) => x.taskId === t.id)!;
      expect(o.taskKey).toBe(keys.get(t.id)!);
      expect(Object.values(o.perDay).reduce((n, d) => n + d.instances, 0)).toBe(t.instances.length);
      expect(o.instances).toBe(t.instances.length);
      expect(Object.keys(o.perDay).sort()).toEqual([...new Set(t.instances.map((i) => dayOf(i.start, "UTC")))].sort());
    }
  });

  test("OBSERVE: share is the task's part of the window's active time", () => {
    const obs = observeWindow(w, keys);
    const total = w.spans.reduce((n, s) => n + s.activeSeconds, 0);
    for (const t of w.tasks) {
      const mine = t.instances.reduce((n, i) => n + i.activeSeconds, 0);
      expect(obs.find((x) => x.taskId === t.id)!.share).toBe(Math.round((mine / total) * 1e4) / 1e4);
    }
    expect(obs.reduce((n, o) => n + o.share, 0)).toBeCloseTo(1, 2);
  });
});

describe("p43a day records", () => {
  test("DAY: one record per closed day of the window; minutes match the spans of that day", () => {
    const { records, episodes } = buildDayRecords(w, keys, NOW);
    expect(records.map((r) => r.day)).toEqual(w.days);
    const sundayNoon = NOW - 86_400_000;
    expect(buildDayRecords(w, keys, sundayNoon).records.map((r) => r.day)).toEqual(w.days.slice(0, 6));
    for (const r of records) {
      const secs = w.spans.filter((s) => dayOf(s.start, "UTC") === r.day).reduce((n, s) => n + s.activeSeconds, 0);
      expect(r.totals.active_minutes.value).toBe(r1(secs / 60));
      expect(r.totals.active_minutes.arithmetic.length).toBeGreaterThan(0);
      expect(r.totals.active_minutes.evidence.length).toBeGreaterThan(0);
      const instances = w.tasks.flatMap((t) => t.instances).filter((i) => dayOf(i.start, "UTC") === r.day).length;
      expect(episodes.filter((e) => e.day === r.day && e.kind === "task_instance").length).toBe(instances);
      const byKind = r.by_kind.reduce((n, k) => n + k.minutes.value, 0);
      expect(Math.abs(byKind - r.totals.active_minutes.value)).toBeLessThan(0.5);
    }
  });

  test("DAY: focus blocks, switches and per-task numbers are computed; deterministic", () => {
    const r = buildDayRecords(w, keys, NOW).records.find((x) => x.day === "2026-10-13")!;
    expect(r.totals.switches.value).toBeGreaterThan(0);
    expect(r.totals.focus_blocks.value).toBeGreaterThanOrEqual(1);
    expect(r.totals.focus_minutes.value).toBeGreaterThanOrEqual(25);
    const mins = r.by_task.map((t) => t.minutes.value);
    expect(mins).toEqual([...mins].sort((a, b) => b - a));
    const outreach = r.by_task.find((t) => t.name === "Outreach emails")!;
    expect(outreach.instances.value).toBeGreaterThanOrEqual(10);
    expect(r.totals.switches_per_active_hour.value).toBe(r1(r.totals.switches.value / (r.totals.active_minutes.value / 60)));
    expect(JSON.stringify(buildDayRecords(w, keys, NOW))).toBe(JSON.stringify(buildDayRecords(w, keys, NOW)));
  });

  test("DAY: days are the member's timezone days, not the server's", () => {
    const at = Date.UTC(2026, 9, 13, 23, 30);
    const mk = (timezone: string, day: string): UnderstandingWindow => ({
      timezone, days: [day],
      spans: [{ id: "sp_1", start: at, end: at + 1_200_000, activeSeconds: 1200, appBundleId: "com.microsoft.Excel", appName: "Microsoft Excel", host: "", title: "Book1", observationIds: ["obs_1"] }],
      tasks: [{ id: "t_1", signature: "s", kind: "sheet.edit", name: "Edit the sheet", appBundleId: "com.microsoft.Excel", appName: "Microsoft Excel", host: "", centroid: null, sameness: 1, instances: [{ id: "i_1", start: at, end: at + 1_200_000, activeSeconds: 1200, spanIds: ["sp_1"], observationIds: ["obs_1"] }] }],
    });
    const later = Date.UTC(2026, 9, 20, 12);
    const karachi = mk("Asia/Karachi", "2026-10-14");
    expect(buildDayRecords(karachi, resolveTaskKeys([], karachi).keys, later).records.map((r) => r.day)).toEqual(["2026-10-14"]);
    const ny = mk("America/New_York", "2026-10-13");
    expect(buildDayRecords(ny, resolveTaskKeys([], ny).keys, later).records.map((r) => r.day)).toEqual(["2026-10-13"]);
    // Not closed yet in Karachi at 2026-10-14 12:00 UTC (17:00 local, same day).
    expect(buildDayRecords(karachi, resolveTaskKeys([], karachi).keys, Date.UTC(2026, 9, 14, 12)).records).toEqual([]);
  });

  test("DAY: every total is a Figure whose id is fig_ + 16 hex of sha256(JCS(figure without id))", () => {
    expect(jcs({ b: 2, a: [1, "x", null, true], c: { z: 0.5, y: 1e21 } })).toBe('{"a":[1,"x",null,true],"b":2,"c":{"y":1e+21,"z":0.5}}');
    const r = buildDayRecords(w, keys, NOW).records[1]!;
    const figs = collectFigures(r);
    expect(figs.length).toBeGreaterThanOrEqual(6);
    for (const k of ["active_minutes", "switches", "switches_per_active_hour", "focus_blocks", "focus_minutes", "meeting_minutes"] as const) {
      const f: Figure = r.totals[k];
      expect(Object.keys(f).sort()).toEqual(["arithmetic", "evidence", "id", "source_purged_at", "unit", "value"]);
      expect(f.source_purged_at).toBeNull();
      const { id, ...rest } = f;
      expect(id).toBe(`fig_${createHash("sha256").update(canon(rest)).digest("hex").slice(0, 16)}`);
      expect(figs.some((x) => x.figure.id === id && x.pointer === `/totals/${k}`)).toBe(true);
    }
  });

  test("DAY: one task_instance episode per instance and one focus_block episode per block of 25 minutes or more", () => {
    const { records, episodes } = buildDayRecords(w, keys, NOW);
    for (const t of w.tasks) for (const i of t.instances) {
      const e = episodes.find((x) => x.id === `ep_${i.id}`)!;
      expect(e.kind).toBe("task_instance");
      expect(e.task_key).toBe(keys.get(t.id)!);
      expect(e.evidence).toEqual(i.observationIds);
      expect(e.minutes).toBe(r1(i.activeSeconds / 60));
    }
    const blocks = episodes.filter((e) => e.kind === "focus_block");
    expect(blocks.length).toBeGreaterThan(0);
    for (const b of blocks) {
      expect(b.id).toMatch(/^ep_fb_[0-9a-f]{12}$/);
      expect(b.minutes).toBeGreaterThanOrEqual(25);
    }
    for (const r of records) {
      expect(r.episode_ids).toEqual(episodes.filter((e) => e.day === r.day).map((e) => e.id).sort());
      expect(r.totals.focus_blocks.value).toBe(blocks.filter((b) => b.day === r.day).length);
    }
  });

  test("LEAKS: episode names have no emails, digits, URLs or raw titles", () => {
    const { episodes, records } = buildDayRecords(w, keys, NOW);
    const titles = new Set(fx.raw.titles);
    const names = [...episodes.map((e) => e.name), ...records.flatMap((r) => r.by_task.map((t) => t.name))];
    expect(names.length).toBeGreaterThan(0);
    for (const n of names) {
      expect(/\d/.test(n)).toBe(false);
      expect(/@|https?:\/\/|www\./.test(n)).toBe(false);
      expect(titles.has(n)).toBe(false);
      expect(n.length).toBeLessThanOrEqual(80);
      expect(n.trim()).toBe(n);
      expect(n.length).toBeGreaterThan(0);
    }
    expect(names).toContain("Reply to about invoice");
  });

  test("LEAKS: links without a scheme are stripped and refused; app names are scrubbed too", () => {
    const raw = "Review github.com/acme/secret-repo/pull and docs.google.com/document/d/abcXYZ";
    expect(hasLeak(raw)).toBe(true);
    expect(safeName(raw)).toBe("Review and");
    expect(hasLeak("Work in www.notion.so")).toBe(false);
    const t = w.tasks[0]!;
    const leaky: UnderstandingWindow = { ...w, tasks: [{ ...t, appName: "Mail dana@fund.example" }] };
    const o = observeWindow(leaky, resolveTaskKeys([], leaky).keys)[0]!;
    expect(hasLeak(o.appName)).toBe(false);
  });
});
