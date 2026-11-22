import type { Hono } from "hono";
import { registerIngestRoutes } from "./batches.ts";
import { registerConsentRoutes } from "./consent.ts";
import type { IngestDeps } from "./context.ts";
import { registerKeyWrapRoutes } from "./keywrap.ts";

export type { IngestDeps } from "./context.ts";
export { uploadConsentState, type UploadConsentState } from "./consent.ts";
export { RETENTION_CRON, RETENTION_WORKFLOW, retentionPurgeWorkflow, runRetentionPurge, scheduleRetentionPurge, type RetentionDeps, type RetentionResult } from "./retention.ts";

/** Mounts the M3 routes: ingest batches, ingest config, keyframe refusal, upload consent and pseudonym key wraps. */
export function registerIngest(app: Hono, deps: IngestDeps): void {
  registerIngestRoutes(app, deps);
  registerConsentRoutes(app, deps);
  registerKeyWrapRoutes(app, deps);
}
