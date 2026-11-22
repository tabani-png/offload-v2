/**
 * App cue table (slice m3-05c-import-signals): the rules the Mac recordings import uses to name the app of a frame
 * without a macOS menu bar, from URL-bar hosts and known window titles in the window chrome. Published here so the
 * cloud (m5-01) can apply the same rules to masked text; the rules and their order are described in the file's
 * `about`. The Swift copy (apps/mac/Sources/OffloadImport/AppCues.swift) is tested equal to this file.
 * Not exported from index.ts: import it as `@offload/contracts/src/app-cues.ts`.
 */
import { z } from "zod";
import table from "../rules/app-cues.json";

/** A bare lowercase host, optionally followed by a path prefix used for matching only (`docs.google.com/spreadsheets`). */
const hostPattern = z
  .string()
  .max(300)
  .regex(/^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+(\/[a-z0-9._~/-]+)?$/);
const title = z.string().min(1).max(64).regex(/^[A-Za-z0-9][A-Za-z0-9 .&'-]*$/);
const appName = z.string().min(1).max(256);
const appBundleId = z.string().min(1).max(255).regex(/^[A-Za-z0-9.-]+$/);

export const AppCueRuleSchema = z.strictObject({
  id: z.string().regex(/^[a-z0-9-]+$/),
  app_name: appName,
  app_bundle_id: appBundleId,
  hosts: z.array(hostPattern),
  titles: z.array(title),
});
export type AppCueRule = z.infer<typeof AppCueRuleSchema>;

export const AppCueTableSchema = z.strictObject({
  version: z.literal(1),
  about: z.string().min(1),
  chrome_band: z.strictObject({ fraction: z.number().gt(0).lt(1), min_px: z.number().int().positive() }),
  browser: z.strictObject({ app_name: appName, app_bundle_id: appBundleId }),
  not_tlds: z.array(z.string().regex(/^[a-z]+$/)),
  apps: z.array(AppCueRuleSchema).min(1),
});
export type AppCueTable = z.infer<typeof AppCueTableSchema>;

/** The table, checked against the schema when this module loads. */
export const appCueTable: AppCueTable = AppCueTableSchema.parse(table);
