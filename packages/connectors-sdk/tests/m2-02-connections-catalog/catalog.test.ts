import { readFileSync } from "node:fs";
import { expect, test } from "bun:test";
import { CatalogEntrySchema, type CatalogEntry } from "@offload/contracts/src/connections/index.ts";
import {
  availableEntries,
  CatalogLoadError,
  findEntry,
  launchCatalog,
  loadCatalog,
  methodAdapter,
} from "../../src/catalog/index.ts";
import { capabilityNames } from "../../src/capabilities.ts";

/** The ADR 0033 launch table: app, provider slug, method, adapter. */
const ADR_0033_TABLE = [
  { app: "Gmail", provider: "gmail", method: "google_internal", adapter: "openapi" },
  { app: "Google Calendar", provider: "google_calendar", method: "google_internal", adapter: "openapi" },
  { app: "Google Sheets", provider: "google_sheets", method: "google_internal", adapter: "openapi" },
  { app: "Google Drive", provider: "google_drive", method: "google_internal", adapter: "openapi" },
  { app: "Slack", provider: "slack", method: "composio", adapter: "composio" },
  { app: "Notion", provider: "notion", method: "mcp", adapter: "mcp" },
  { app: "Linear", provider: "linear", method: "mcp", adapter: "mcp" },
  { app: "Stripe", provider: "stripe", method: "openapi", adapter: "openapi" },
  { app: "QuickBooks", provider: "quickbooks", method: "composio", adapter: "composio" },
  { app: "Xero", provider: "xero", method: "composio", adapter: "composio" },
] as const;

const S5_DATE = "2026-11-20T10:00:00Z";

test("CATALOG: every app in the ADR 0033 table has exactly one entry with its method and adapter", () => {
  const catalog = launchCatalog();
  expect(catalog).toHaveLength(10);

  const providers = catalog.map((e) => e.provider);
  expect(new Set(providers).size).toBe(providers.length);

  for (const row of ADR_0033_TABLE) {
    const matches = catalog.filter((e) => e.app === row.app);
    expect(matches).toHaveLength(1);
    const entry = matches[0] as CatalogEntry;
    expect({ app: entry.app, provider: entry.provider, method: entry.method, adapter: entry.adapter }).toEqual({
      ...row,
    });
    expect(findEntry(catalog, row.provider)).toEqual(entry);
    expect(methodAdapter(row.method)).toBe(row.adapter);
  }
  expect(findEntry(catalog, "not_in_catalog")).toBeUndefined();
});

test("CATALOG: launchCatalog returns a fresh copy each call", () => {
  const first = launchCatalog();
  (first[0] as CatalogEntry).s5_verified_at = S5_DATE;
  (first[0] as CatalogEntry).capabilities.push("mail.send");
  const second = launchCatalog();
  expect((second[0] as CatalogEntry).s5_verified_at).toBeNull();
  expect(second).not.toBe(first);
});

test("CATALOG: every entry validates against CatalogEntry and ships unverified", () => {
  const catalog = launchCatalog();
  for (const entry of catalog) {
    expect(CatalogEntrySchema.parse(entry)).toEqual(entry);
    expect(entry.s5_verified_at).toBeNull();
  }

  // The raw data file itself: ten entries, all unverified, every capability in the vocabulary.
  const raw = JSON.parse(readFileSync(new URL("../../src/catalog/launch.json", import.meta.url), "utf8")) as unknown;
  expect(Array.isArray(raw)).toBe(true);
  const rawEntries = raw as Record<string, unknown>[];
  expect(rawEntries).toHaveLength(10);
  const vocabulary = new Set(capabilityNames());
  for (const e of rawEntries) {
    const parsed = CatalogEntrySchema.parse(e);
    expect(parsed.s5_verified_at).toBeNull();
    for (const cap of parsed.capabilities) expect(vocabulary.has(cap)).toBe(true);
  }
  expect(loadCatalog(raw)).toEqual(catalog);

  // A mismatched adapter for the method is refused.
  const mismatched = launchCatalog().map((e) => (e.provider === "gmail" ? { ...e, adapter: "composio" } : e));
  expect(() => loadCatalog(mismatched)).toThrow(CatalogLoadError);

  // A duplicate provider is refused.
  const base = launchCatalog();
  const duplicated = [...base, { ...(base[0] as CatalogEntry), app: "Gmail Again" }];
  expect(() => loadCatalog(duplicated)).toThrow(CatalogLoadError);

  // A capability outside the vocabulary is refused.
  const unknownCap = launchCatalog().map((e) =>
    e.provider === "stripe" ? { ...e, capabilities: [...e.capabilities, "payouts.teleport"] } : e,
  );
  expect(() => loadCatalog(unknownCap)).toThrow(CatalogLoadError);

  // Not a valid CatalogEntry at all.
  expect(() => loadCatalog([{ app: "Gmail" }])).toThrow(CatalogLoadError);
  expect(() => loadCatalog({ not: "an array" })).toThrow(CatalogLoadError);

  try {
    loadCatalog(duplicated);
    throw new Error("expected CatalogLoadError");
  } catch (err) {
    expect(err).toBeInstanceOf(CatalogLoadError);
    expect((err as CatalogLoadError).code).toBe("catalog_invalid");
  }
});

test("CATALOG: availableEntries returns only entries verified in spike S5", () => {
  expect(availableEntries(launchCatalog())).toEqual([]);

  const dated = launchCatalog().map((e) =>
    e.provider === "stripe" || e.provider === "google_sheets" ? { ...e, s5_verified_at: S5_DATE } : e,
  );
  const available = availableEntries(dated);
  expect(available.map((e) => e.provider).sort()).toEqual(["google_sheets", "stripe"]);
  for (const e of available) expect(e.s5_verified_at).toBe(S5_DATE);
});
