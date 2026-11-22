import { expect, test } from "bun:test";
import { buildUnderstandingWindow } from "../../src/understanding/window.ts";
import { invoiceImport, recordingObservations, rng, merge } from "./fixtures.ts";

const DAYS = ["2026-11-09", "2026-11-10", "2026-11-11"];
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

test("WINDOW: the same observations give the same window with deterministic ids", async () => {
  const fx = invoiceImport(DAYS, { perDay: 2 });
  const a = await buildUnderstandingWindow({ timezone: "UTC", days: DAYS, observations: fx.observations, texts: fx.texts });
  const b = await buildUnderstandingWindow({ timezone: "UTC", days: DAYS, observations: [...fx.observations].reverse(), texts: [...fx.texts].reverse() });
  expect(b).toEqual(a);
  for (const s of a.spans) expect(s.id).toMatch(UUID);
  for (const t of a.tasks) for (const i of t.instances) expect(i.id).toMatch(UUID);
  const ids = [...a.spans.map((s) => s.id), ...a.tasks.flatMap((t) => t.instances.map((i) => i.id))];
  expect(new Set(ids).size).toBe(ids.length);
  for (const s of a.spans) expect(s.activeSeconds).toBe(Math.round((s.end - s.start) / 1000));
});

test("WINDOW: spans and days are in the member's timezone and only the asked days are kept", async () => {
  const r = rng(21);
  const seg = { app: { bundle: "com.apple.mail", name: "Mail", title: "Inbox" }, seconds: 120, frames: ["Inbox reply customer"] };
  const b = merge([
    recordingObservations({ start: Date.parse("2026-11-10T23:30:00Z"), source: "live", segments: [seg] }, r), // 18:30 on the 10th in New York
    recordingObservations({ start: Date.parse("2026-11-11T06:00:00Z"), source: "live", segments: [seg] }, r), // 01:00 on the 11th in New York
  ]);
  const ny = await buildUnderstandingWindow({ timezone: "America/New_York", days: ["2026-11-10"], observations: b.observations, texts: b.texts });
  expect(ny.timezone).toBe("America/New_York");
  expect(ny.days).toEqual(["2026-11-10"]);
  expect(ny.spans.map((s) => new Date(s.start).toISOString())).toEqual(["2026-11-10T23:30:00.000Z"]);
  const utc = await buildUnderstandingWindow({ timezone: "UTC", days: ["2026-11-10"], observations: b.observations, texts: b.texts });
  expect(utc.spans.map((s) => new Date(s.start).toISOString())).toEqual(["2026-11-10T23:30:00.000Z"]);
  const both = await buildUnderstandingWindow({ timezone: "UTC", days: ["2026-11-10", "2026-11-11"], observations: b.observations, texts: b.texts });
  expect(both.spans).toHaveLength(2);
});

test("WINDOW: no text snapshot content reaches the window", async () => {
  const fx = invoiceImport(DAYS, { perDay: 2 });
  const w = await buildUnderstandingWindow({ timezone: "UTC", days: DAYS, observations: fx.observations, texts: fx.texts });
  // Centroids and sameness are numbers from code; everything else is checked for text.
  const json = JSON.stringify({ ...w, tasks: w.tasks.map((t) => ({ ...t, centroid: null, sameness: null })) });
  for (const word of ["attachment", "Download", "tomato", "sunset", "Reference", "entered"]) expect(json).not.toContain(word);
  // Amounts only appear in text snapshots.
  expect(json).not.toMatch(/\d+\.\d\d\b/);
  for (const t of w.tasks) expect(t.name).not.toMatch(/[<>\d]/);
});
