import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { ObservationSchema } from "../../src/index.ts";
import { AppCueTableSchema, appCueTable } from "../../src/app-cues.ts";
import { focus } from "../m1-02-contracts-ingest/fixtures.ts";

// m3-05c-import-signals: the app cue table the Mac applies to recordings without a menu bar, published for the cloud
// (m5-01). The Swift copy is checked against this file by the M305C TABLE test.
const raw: unknown = JSON.parse(readFileSync(new URL("../../rules/app-cues.json", import.meta.url), "utf8"));

test("TABLE: app-cues.json parses with the AppCueTable schema and is what appCueTable holds", () => {
  const parsed = AppCueTableSchema.parse(raw);
  expect(parsed).toEqual(appCueTable);
  expect(appCueTable.version).toBe(1);
  expect(appCueTable.browser).toEqual({ app_name: "Browser", app_bundle_id: "recording.browser" });
  expect(appCueTable.chrome_band).toEqual({ fraction: 0.18, min_px: 96 });
  // The schema is strict: an unknown key or a missing list is refused.
  expect(AppCueTableSchema.safeParse({ ...appCueTable, extra: 1 }).success).toBe(false);
  const first = appCueTable.apps[0];
  expect(first).toBeDefined();
  expect(AppCueTableSchema.safeParse({ ...appCueTable, apps: [{ ...first, hosts: undefined }] }).success).toBe(false);
});

test("TABLE: hosts are lowercase bare hosts with an optional path prefix, never a scheme, query or fragment", () => {
  const bad = ["https://mail.google.com", "Mail.Google.com", "mail.google.com?x=1", "mail.google.com#inbox", "mail.google.com:443", "-x.com", "com"];
  for (const host of bad) {
    const table = { ...appCueTable, apps: [{ id: "x", app_name: "X", app_bundle_id: "web.x", hosts: [host], titles: [] }] };
    expect(AppCueTableSchema.safeParse(table).success).toBe(false);
  }
  for (const app of appCueTable.apps) {
    for (const host of app.hosts) expect(host).toMatch(/^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+(\/[a-z0-9._~\/-]+)?$/);
  }
  const sheets = appCueTable.apps.find((a) => a.id === "google-sheets");
  expect(sheets?.hosts).toContain("docs.google.com/spreadsheets");
});

test("TABLE: ids and titles are unique, every app has a host or a title, and the brief's six titles are present", () => {
  const ids = appCueTable.apps.map((a) => a.id);
  expect(new Set(ids).size).toBe(ids.length);
  const titles = appCueTable.apps.flatMap((a) => a.titles.map((t) => t.toLowerCase()));
  expect(new Set(titles).size).toBe(titles.length);
  for (const app of appCueTable.apps) expect(app.hosts.length + app.titles.length).toBeGreaterThan(0);
  for (const title of ["Gmail", "QuickBooks", "HubSpot", "Slack", "Excel", "Google Sheets"]) {
    expect(appCueTable.apps.some((a) => a.titles.includes(title))).toBe(true);
  }
  expect(appCueTable.not_tlds).toContain("xlsx");
  expect(appCueTable.not_tlds).toContain("pdf");
});

test("TABLE: every app name, bundle id and host fits the observation contract's focus", () => {
  const apps = [...appCueTable.apps, { ...appCueTable.browser, hosts: ["portal.example.com"] }];
  for (const app of apps) {
    const host = app.hosts[0]?.split("/")[0];
    const candidate = { ...focus, app_bundle_id: app.app_bundle_id, app_name: app.app_name, source: "import",
      import_id: "4f1c2a9e-8d7b-4c3a-9f2e-1b0a9c8d7e6f", ...(host ? { host } : {}) };
    const result = ObservationSchema.safeParse(candidate);
    expect(result.success).toBe(true);
  }
});
