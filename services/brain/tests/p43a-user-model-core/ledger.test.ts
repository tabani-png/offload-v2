// Task ledger: stable task keys across weeks (carried from old s36 ledger.test.ts, plus centroid matching).
import { describe, expect, test } from "bun:test";
import { CENTROID_MATCH, cosine, resolveTaskKeys } from "../../src/user-model/ledger.ts";
import type { UnderstandingWindow, WindowTask } from "../../src/user-model/ports.ts";
import { fixtureWeek, MONDAYS, taskOf } from "../fixtures/window.ts";

const w1 = fixtureWeek(MONDAYS[0]);
const w2 = fixtureWeek("2026-10-26", { seed: 7 });
const only = (w: UnderstandingWindow, tasks: WindowTask[]): UnderstandingWindow => ({ ...w, tasks });

/** A unit vector with the given cosine to `base`. */
function atCosine(base: readonly number[], c: number): number[] {
  const n = Math.hypot(...base);
  const u = base.map((x) => x / n);
  const e: number[] = u.map((_, i) => (i === u.length - 1 ? 1 : 0));
  const dot = e.reduce((s, x, i) => s + x * u[i]!, 0);
  const w0 = e.map((x, i) => x - dot * u[i]!);
  const wn = Math.hypot(...w0);
  const w = w0.map((x) => x / wn);
  return u.map((x, i) => c * x + Math.sqrt(1 - c * c) * w[i]!);
}

describe("p43a task ledger", () => {
  test("LEDGER: two weeks of the same work keep the same taskKeys (>= 95% of active time)", () => {
    const r1 = resolveTaskKeys([], w1.window);
    const r2 = resolveTaskKeys(r1.ledger, w2.window);
    const k1 = new Set(r1.keys.values());
    let same = 0;
    let total = 0;
    for (const t of w2.window.tasks) {
      const s = t.instances.reduce((n, i) => n + i.activeSeconds, 0);
      total += s;
      if (k1.has(r2.keys.get(t.id)!)) same += s;
    }
    expect(total).toBeGreaterThan(0);
    expect(same / total).toBeGreaterThanOrEqual(0.95);
    for (const key of r2.keys.values()) expect(key).toMatch(/^k_[0-9a-f]{12}$/);
  });

  test("LEDGER: a renamed-but-same task (new signature, same kind/app/host/name words) maps to the old key", () => {
    const r1 = resolveTaskKeys([], w1.window);
    const t = taskOf(w1, "outreach");
    const renamed: WindowTask = { ...t, id: "t_renamed", signature: "a different signature", centroid: null, name: "Outreach emails sent" };
    const r2 = resolveTaskKeys(r1.ledger, only(w1.window, [renamed]));
    expect(r2.keys.get("t_renamed")).toBe(r1.keys.get(t.id)!);
  });

  test("LEDGER: a genuinely new task gets a new key; two tasks in one window never share a key", () => {
    const r1 = resolveTaskKeys([], w1.window);
    expect(new Set(r1.keys.values()).size).toBe(w1.window.tasks.length);
    const t = w1.window.tasks[0]!;
    const fresh: WindowTask = { ...t, id: "t_new", kind: "docs.write-spec", name: "Writing specs", signature: "new", appBundleId: "com.apple.iWork.Pages", appName: "Pages", host: "", centroid: [0, 0, 0, 0, 0, 0, 0, 1] };
    const r2 = resolveTaskKeys(r1.ledger, only(w1.window, [fresh]));
    expect(new Set(r1.keys.values()).has(r2.keys.get("t_new")!)).toBe(false);
    expect(r2.ledger.length).toBe(r1.ledger.length + 1);
  });

  test("LEDGER: deterministic", () => {
    const a = resolveTaskKeys([], w1.window);
    const b = resolveTaskKeys([], w1.window);
    expect(JSON.stringify([...a.keys])).toBe(JSON.stringify([...b.keys]));
    expect(JSON.stringify(a.ledger)).toBe(JSON.stringify(b.ledger));
  });

  test("LEDGER: centroid cosine >= 0.85 maps a task with a new signature and new name to its old key; below 0.85 mints a new key", () => {
    expect(CENTROID_MATCH).toBe(0.85);
    const r1 = resolveTaskKeys([], w1.window);
    const t = taskOf(w1, "review");
    const old = t.centroid!;
    expect(cosine(old, atCosine(old, 0.86))).toBeCloseTo(0.86, 6);
    const near: WindowTask = { ...t, id: "t_near", signature: "sig-near", name: "Pull request feedback", centroid: atCosine(old, 0.86) };
    const far: WindowTask = { ...t, id: "t_far", signature: "sig-far", name: "Pull request feedback", centroid: atCosine(old, 0.84) };
    expect(resolveTaskKeys(r1.ledger, only(w1.window, [near])).keys.get("t_near")).toBe(r1.keys.get(t.id)!);
    const r3 = resolveTaskKeys(r1.ledger, only(w1.window, [far]));
    expect(new Set(r1.keys.values()).has(r3.keys.get("t_far")!)).toBe(false);
  });

  test("LEDGER: two tasks whose masked names have no words do not match by name", () => {
    const base = taskOf(w1, "slack");
    const a: WindowTask = { ...base, id: "t_a", signature: "sig-a", name: "1234", centroid: null };
    const b: WindowTask = { ...base, id: "t_b", signature: "sig-b", name: "#5 / 77", centroid: null };
    const r1 = resolveTaskKeys([], only(w1.window, [a]));
    const r2 = resolveTaskKeys(r1.ledger, only(w1.window, [b]));
    expect(r2.keys.get("t_b")).not.toBe(r1.keys.get("t_a")!);
  });

  test("LEDGER: a task with no instances gets no key and no ledger entry", () => {
    const t: WindowTask = { ...taskOf(w1, "report"), id: "t_empty", signature: "sig-empty", instances: [] };
    const r = resolveTaskKeys([], only(w1.window, [t]));
    expect(r.keys.has("t_empty")).toBe(false);
    expect(r.ledger).toEqual([]);
  });
});
