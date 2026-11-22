import { expect, test } from "bun:test";
import { cueOf, isStandInApp } from "../../src/understanding/cues.ts";
import { describeSpan } from "../../src/understanding/describe.ts";
import { sessionize } from "../../src/understanding/sessionize.ts";
import { buildUnderstandingWindow } from "../../src/understanding/window.ts";
import { invoiceSegments, merge, NOISE, recordingObservations, rng, utc } from "./fixtures.ts";

const DAY = "2026-11-10";

test("CUE: a recording without a menu bar gets its host from URL bar text and its app from window chrome text", () => {
  expect(isStandInApp("recording.unknown", "Screen")).toBe(true);
  expect(isStandInApp("screenwatch.screen", "Screen")).toBe(true);
  expect(isStandInApp("recording.keynote", "Keynote")).toBe(false);
  expect(isStandInApp("com.apple.mail", "Mail")).toBe(false);
  expect(cueOf("Google Chrome https://app.ledgerly.example New bill")).toEqual({ appBundleId: "com.google.Chrome", appName: "Google Chrome", host: "app.ledgerly.example" });
  expect(cueOf("www.video.example Pasta recipe")).toEqual({ host: "video.example" });
  expect(cueOf("Edit billing.ts and README.md, see Node.js notes")).toEqual({});
  // Window chrome is at the top: an app name inside the body text is not a cue.
  expect(cueOf("Notes from the call\nask the Slack admin and check Preview of the deck")).toEqual({});
  expect(cueOf("Pasta recipe we saw in Mail yesterday")).toEqual({});
  expect(cueOf("Inbox\nMail\nInvoice from supplier")).toEqual({ appBundleId: "com.apple.mail", appName: "Mail" });
  const r = rng(3);
  const built = recordingObservations({ start: utc(DAY) + 9 * 3_600_000, segments: invoiceSegments(r, { menuBar: false }) }, r);
  expect(built.observations.filter((x) => x.kind === "focus")).toHaveLength(1);
  const spans = sessionize(built.observations, built.texts);
  expect(spans.map((s) => [s.appBundleId, s.appName, s.host, s.standIn, s.cued])).toEqual([
    ["com.apple.mail", "Mail", "", true, true],
    ["com.google.Chrome", "Google Chrome", "app.ledgerly.example", true, true],
    ["com.microsoft.Excel", "Microsoft Excel", "", true, true],
  ]);
});

test("CUE: two unrelated recordings on the stand-in app within 15 min stay two spans", () => {
  const r = rng(4);
  const start = utc(DAY) + 14 * 3_600_000;
  const quiet = { ...NOISE[3]!, seconds: 60 };
  const a = recordingObservations({ start, segments: [quiet] }, r);
  const b = recordingObservations({ start: start + 4 * 60_000, segments: [quiet] }, r);
  const spans = sessionize(merge([a, b]).observations, []);
  expect(spans).toHaveLength(2);
  expect(spans.every((s) => s.standIn && !s.cued)).toBe(true);
});

test("CUE: a stand-in span with no text and no cue joins no task", async () => {
  const r = rng(5);
  const built = merge([
    recordingObservations({ start: utc(DAY) + 14 * 3_600_000, segments: [NOISE[3]!] }, r),
    recordingObservations({ start: utc(DAY) + 15 * 3_600_000, segments: [NOISE[3]!] }, r),
  ]);
  const spans = sessionize(built.observations, built.texts);
  expect(spans.map((s) => describeSpan(s, "UTC").joinable)).toEqual([false, false]);
  const w = await buildUnderstandingWindow({ timezone: "UTC", days: [DAY], observations: built.observations, texts: built.texts });
  expect(w.spans).toHaveLength(2);
  expect(w.tasks).toEqual([]);
});
