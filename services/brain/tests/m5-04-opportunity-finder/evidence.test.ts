import { expect, test } from "bun:test";
import { buildTaskEvidence } from "../../src/opportunities/evidence.ts";
import { ep, weekWith } from "./fixtures.ts";

const K = "k_aaaaaaaaaaaa";
const W45 = { w: "2026-W45", from: "2026-11-02", to: "2026-11-08" } as const;

test("EVIDENCE: a week's evidence counts instances, minutes and days and lists hosts and desktop apps as systems", () => {
  const week = weekWith(W45.w, W45.from, W45.to, [
    { task_key: K, name: "Copy invoices into the books", minutes: 40, instances: 4, median: 10 },
    { task_key: "k_bbbbbbbbbbbb", name: "Unseen task", minutes: 5, instances: 1, median: 5 },
  ]);
  const episodes = [
    ep("ep_1", K, "2026-11-02T09:00:00Z", 10, ["com.google.Chrome", "com.microsoft.Excel"], ["mail.google.com", "app.ledgerly.example"]),
    ep("ep_2", K, "2026-11-02T11:00:00Z", 10, ["com.google.Chrome"], ["app.ledgerly.example"]),
    ep("ep_3", K, "2026-11-04T09:00:00Z", 10, ["com.microsoft.Excel"], []),
    ep("ep_4", K, "2026-11-04T15:00:00Z", 10, ["com.google.Chrome"], ["mail.google.com"]),
    // The week before: not this week's instance, not a day of this week.
    ep("ep_0", K, "2026-10-28T09:00:00Z", 10, ["com.apple.mail"], []),
    { ...ep("ep_fb", K, "2026-11-03T09:00:00Z", 30, ["us.zoom.xos"], []), kind: "focus_block" as const },
  ];
  const out = buildTaskEvidence({ week, episodes, timezone: "UTC" });
  expect(out.map((e) => e.task_key)).toEqual([K, "k_bbbbbbbbbbbb"]);
  expect(out[0]).toEqual({
    task_key: K, name: "Copy invoices into the books", iso_week: "2026-W45", minutes: 40, instances: 4, median_minutes: 10, days: 2,
    systems: [
      { id: "app.ledgerly.example", surface: "web", work_kind: "browse" },
      { id: "com.microsoft.Excel", surface: "desktop", work_kind: "sheet" },
      { id: "mail.google.com", surface: "web", work_kind: "email" },
    ],
    cadence: null, episode_ids: ["ep_1", "ep_2", "ep_3", "ep_4"],
  });
  expect(out[1]!.systems).toEqual([]);
  expect(out[1]!.days).toBe(0);
});

test("EVIDENCE: browsers and stand-in apps are not systems", () => {
  const week = weekWith(W45.w, W45.from, W45.to, [{ task_key: K, name: "Pipeline update", minutes: 30, instances: 3, median: 10 }]);
  const episodes = [
    ep("ep_1", K, "2026-11-02T09:00:00Z", 10, ["recording.unknown", "com.google.Chrome", "screenwatch.screen", "com.apple.Safari"], []),
    ep("ep_2", K, "2026-11-03T09:00:00Z", 10, ["recording.unknown"], ["crm.dealbook.example"]),
  ];
  const [e] = buildTaskEvidence({ week, episodes, timezone: "UTC" });
  expect(e!.systems).toEqual([{ id: "crm.dealbook.example", surface: "web", work_kind: "browse" }]);
});

test("EVIDENCE: one instance a day at the same hour is a daily cadence; the same weekday across weeks is weekly", () => {
  // New York is UTC-5 in November: 14:05Z is 09:05 local.
  const week = weekWith(W45.w, W45.from, W45.to, [
    { task_key: K, name: "Morning numbers", minutes: 60, instances: 4, median: 15 },
    { task_key: "k_cccccccccccc", name: "Friday report", minutes: 40, instances: 1, median: 40 },
    { task_key: "k_dddddddddddd", name: "Twice on Monday", minutes: 40, instances: 4, median: 10 },
  ]);
  const xl = ["com.microsoft.Excel"];
  const episodes = [
    ep("ep_d1", K, "2026-11-02T14:05:00Z", 15, xl, []), ep("ep_d2", K, "2026-11-03T14:40:00Z", 15, xl, []),
    ep("ep_d3", K, "2026-11-04T15:10:00Z", 15, xl, []), ep("ep_d4", K, "2026-11-05T13:50:00Z", 15, xl, []),
    ep("ep_w1", "k_cccccccccccc", "2026-10-30T21:00:00Z", 40, xl, []), ep("ep_w2", "k_cccccccccccc", "2026-11-06T21:30:00Z", 40, xl, []),
    ep("ep_t1", "k_dddddddddddd", "2026-11-02T14:00:00Z", 10, xl, []), ep("ep_t2", "k_dddddddddddd", "2026-11-02T15:00:00Z", 10, xl, []),
    ep("ep_t3", "k_dddddddddddd", "2026-11-03T14:00:00Z", 10, xl, []), ep("ep_t4", "k_dddddddddddd", "2026-11-04T14:00:00Z", 10, xl, []),
  ];
  const out = buildTaskEvidence({ week, episodes, timezone: "America/New_York" });
  expect(out[0]!.cadence).toEqual({ kind: "daily", weekday: null, hour: 9 });
  // Fridays 17:00 (EDT) and 16:30 (EST) local, two weeks running.
  expect(out[1]!.cadence).toEqual({ kind: "weekly", weekday: 4, hour: 16 });
  expect(out[1]!.days).toBe(1);
  // Two instances on one day: not a daily cadence.
  expect(out[2]!.cadence).toBeNull();
});

test("EVIDENCE: start times over 2 h apart, different weekdays, two in one week or an instance 9 weeks back give no cadence (review 1 finding 1)", () => {
  const xl = ["com.microsoft.Excel"];
  const keys = ["k_000000000011", "k_000000000012", "k_000000000013", "k_000000000014", "k_000000000015"];
  const week = weekWith(W45.w, W45.from, W45.to, keys.map((k) => ({ task_key: k, name: k, minutes: 30, instances: 3, median: 10 })));
  const episodes = [
    // Daily, but 09:00, 12:30 and 09:10: a 3.5 h band.
    ep("ep_a1", keys[0]!, "2026-11-02T09:00:00Z", 10, xl, []), ep("ep_a2", keys[0]!, "2026-11-03T12:30:00Z", 10, xl, []), ep("ep_a3", keys[0]!, "2026-11-04T09:10:00Z", 10, xl, []),
    // One a week, but Thursday then Friday.
    ep("ep_b1", keys[1]!, "2026-10-29T16:00:00Z", 10, xl, []), ep("ep_b2", keys[1]!, "2026-11-06T16:00:00Z", 10, xl, []),
    // Fridays, but 09:00 then 16:00.
    ep("ep_c1", keys[2]!, "2026-10-30T09:00:00Z", 10, xl, []), ep("ep_c2", keys[2]!, "2026-11-06T16:00:00Z", 10, xl, []),
    // Fridays at 16:00, but twice in one week.
    ep("ep_d1", keys[3]!, "2026-10-23T16:00:00Z", 10, xl, []), ep("ep_d2", keys[3]!, "2026-10-30T16:00:00Z", 10, xl, []),
    ep("ep_d3", keys[3]!, "2026-10-30T16:30:00Z", 10, xl, []), ep("ep_d4", keys[3]!, "2026-11-06T16:10:00Z", 10, xl, []),
    // Fridays at 16:00, but the other one is 9 weeks back (outside the 8 weeks).
    ep("ep_e1", keys[4]!, "2026-09-11T16:00:00Z", 10, xl, []), ep("ep_e2", keys[4]!, "2026-11-06T16:00:00Z", 10, xl, []),
  ];
  const out = buildTaskEvidence({ week, episodes, timezone: "UTC" });
  expect(out.map((e) => e.cadence)).toEqual([null, null, null, null, null]);
  // Control: the same Friday pair inside the 8 weeks is weekly.
  const inside = buildTaskEvidence({ week, episodes: [ep("ep_f1", keys[4]!, "2026-10-30T16:00:00Z", 10, xl, []), ep("ep_f2", keys[4]!, "2026-11-06T16:00:00Z", 10, xl, [])], timezone: "UTC" });
  expect(inside[4]!.cadence).toEqual({ kind: "weekly", weekday: 4, hour: 16 });
});
