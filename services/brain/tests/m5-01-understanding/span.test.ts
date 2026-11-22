import { expect, test } from "bun:test";
import { sessionize } from "../../src/understanding/sessionize.ts";
import type { CaptureObservation, CaptureText } from "../../src/understanding/types.ts";

const D = "0193a6f2-0000-7000-8000-0000000000d1";
const T0 = Date.UTC(2026, 10, 10, 9, 0, 0);
const S = 1000;

function o(id: string, at: number, kind: CaptureObservation["kind"], app?: [string, string, string?, string?]): CaptureObservation {
  return {
    device_id: D, object_id: id, ts: T0 + at * S, kind, app_bundle_id: app?.[0] ?? null, app_name: app?.[1] ?? null, title: app?.[2] ?? null,
    host: app?.[3] ?? null, doc: null, keys: null, clicks: null, source: "live", import_id: null,
  };
}
const txt = (id: string, at: number, text: string): CaptureText => ({ device_id: D, object_id: id, ts: T0 + at * S, text, text_source: "ax", app_bundle_id: null });
const MAIL: [string, string, string] = ["com.apple.mail", "Mail", "Inbox"];
const XL: [string, string, string] = ["com.microsoft.Excel", "Microsoft Excel", "Log"];
const WEB: [string, string, string, string] = ["com.google.Chrome", "Google Chrome", "Bills", "app.ledgerly.example"];
const shape = (spans: ReturnType<typeof sessionize>) =>
  spans.map((s) => ({ app: s.appBundleId, host: s.host, start: (s.start - T0) / S, end: (s.end - T0) / S, active: s.activeMs / S, obs: s.observationIds }));

test("SPAN: golden event fixture gives exact spans (10 s minimum, idle backdated 120 s)", () => {
  const events = [
    o("O1", 0, "focus", MAIL), // 5 s blip: joins the contiguous Excel span
    o("O2", 5, "focus", XL),
    o("O3", 65, "focus", MAIL),
    o("O4", 365, "idle_start"), // detected 120 s after the last input: Mail ends at 245
    o("O5", 1200, "idle_end"), // 955 s of idle: more than 15 min, so a new Mail span
    o("O6", 1300, "focus", WEB),
    o("O7", 1470, "idle_start"),
  ];
  const spans = sessionize(events, []);
  expect(shape(spans)).toEqual([
    { app: "com.microsoft.Excel", host: "", start: 0, end: 65, active: 65, obs: ["O1", "O2"] },
    { app: "com.apple.mail", host: "", start: 65, end: 245, active: 180, obs: ["O3"] },
    { app: "com.apple.mail", host: "", start: 1200, end: 1300, active: 100, obs: ["O3", "O5"] },
    { app: "com.google.Chrome", host: "app.ledgerly.example", start: 1300, end: 1350, active: 50, obs: ["O6"] },
  ]);
  const ids = spans.map((s) => s.id);
  expect(new Set(ids).size).toBe(4);
  for (const id of ids) expect(id).toMatch(/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/);
  expect(sessionize([...events].reverse(), []).map((s) => s.id)).toEqual(ids);
});

test("SPAN: idle up to 15 min merges one focus; a longer idle splits it; pause ends a span", () => {
  const merged = sessionize([o("A", 0, "focus", MAIL), o("B", 200, "idle_start"), o("C", 600, "idle_end"), o("E", 750, "idle_start")], []);
  expect(shape(merged)).toEqual([{ app: "com.apple.mail", host: "", start: 0, end: 630, active: 110, obs: ["A", "C"] }]);
  const paused = sessionize([o("A", 0, "focus", MAIL), o("P", 60, "pause"), o("R", 120, "resume"), o("F", 200, "focus", XL), o("I", 380, "idle_start")], []);
  expect(shape(paused).map((s) => [s.app, s.start, s.end])).toEqual([
    ["com.apple.mail", 0, 60],
    ["com.microsoft.Excel", 200, 260],
  ]);
});

test("SPAN: text snapshots attach to the span open at their time", () => {
  const spans = sessionize(
    [o("A", 0, "focus", MAIL), o("B", 30, "focus", XL), o("I", 180, "idle_start")],
    [txt("T1", 10, "Inbox invoice"), txt("T2", 40, "Log row"), txt("T3", 170, "after input stopped")],
  );
  expect(spans.map((s) => s.texts)).toEqual([["Inbox invoice"], ["Log row"]]);
  expect(spans.map((s) => s.observationIds)).toEqual([["A", "T1"], ["B", "T2"]]);
});

test("SPAN: a text read at the instant of a focus change belongs to the new app", () => {
  // idle_end, the new focus and its first text share one ts (the recordings import writes them so); their ids sort
  // the other way round, so only the order by kind puts the text on the new app.
  const spans = sessionize(
    [o("A", 0, "focus", MAIL), o("Z1", 60, "idle_start"), o("Z3", 300, "idle_end"), o("Z2", 300, "focus", XL), o("Z9", 500, "idle_start")],
    [txt("Z0", 300, "Log row entered")],
  );
  expect(spans.map((s) => [s.appBundleId, s.texts])).toEqual([["com.microsoft.Excel", ["Log row entered"]]]);
});
