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

test("CUE: a host needs a URL-bar shape: OCR words joined by a period are not hosts, and body lines name no app", () => {
  for (const t of ["Meeting with Mr.Smith at noon", "Approved by J.Doe", "Thanks for the update.Regards", "Total due.Pay now", "see section 4.Overview", "thanks for the update.regards"]) {
    expect(cueOf(t)).toEqual({});
  }
  // A URL bar: a scheme, www., or a lowercase host on a chrome line.
  expect(cueOf("https://billing.example.com/inv")).toEqual({ host: "billing.example.com" });
  expect(cueOf("app.ledgerly.example New bill")).toEqual({ host: "app.ledgerly.example" });
  expect(cueOf("Weekly notes\nagenda items\nsee app.ledgerly.example later")).toEqual({});
  // An app name opening line 3 or later is body text.
  expect(cueOf("Weekly notes\nagenda items\nMail merge steps")).toEqual({});
});

test("CUE: a period-joined name in OCR text never becomes a span's or a task's host", async () => {
  const r = rng(6);
  const text = "Call notes with Mr.Smith about the invoice dispute";
  const b = merge([0, 1].map((i) => recordingObservations({ start: utc(DAY) + (9 + i) * 3_600_000, segments: [{ ...NOISE[0]!, frames: [text, text] }] }, r)));
  const w = await buildUnderstandingWindow({ timezone: "UTC", days: [DAY], observations: b.observations, texts: b.texts });
  expect(w.spans.map((s) => s.host)).toEqual(["", ""]);
  expect(w.tasks.map((t) => t.host)).toEqual(w.tasks.map(() => ""));
  expect(JSON.stringify(w)).not.toMatch(/smith/i);
});

test("CUE: a host-shaped OCR token needs a real top-level domain and must be lowercase as read", () => {
  for (const t of ["Inbox\nfrom j.r.smith regarding", "Notes e.g.invoices due", "Reply i.e.tomorrow works", "Report v2.final.draft", "Weekly Report.com summary"]) {
    expect(cueOf(t)).toEqual({});
  }
  expect(cueOf("crm.dealbook.example Pipeline")).toEqual({ host: "crm.dealbook.example" });
  expect(cueOf("mail.google.com Inbox")).toEqual({ host: "mail.google.com" });
});
