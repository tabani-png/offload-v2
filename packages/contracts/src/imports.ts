import { z } from "zod";
import { rfc3339, uuid } from "./primitives.ts";

/**
 * Import spaces (recordings import, M3 tasks m3-05 and m3-05b) and forget requests (docs/API.md "Profile and
 * privacy", DATA_MODEL.md `imports`, `purge_requests`).
 */

/** DATA_MODEL `imports.source_kind`. A folder with videos and screenshots is one import of kind `videos`. */
export const IMPORT_SOURCE_KINDS = ["screenwatch", "screenshots", "videos"] as const;
export const ImportSourceKindSchema = z.enum(IMPORT_SOURCE_KINDS);
export type ImportSourceKind = z.infer<typeof ImportSourceKindSchema>;

const day = z.iso.date();

/** `POST /v1/imports` body. */
export const OpenImportRequestSchema = z.strictObject({ source_kind: ImportSourceKindSchema });
export type OpenImportRequest = z.infer<typeof OpenImportRequestSchema>;

/** `POST /v1/imports` answer (201). */
export const OpenImportResponseSchema = z.strictObject({ import_id: uuid });
export type OpenImportResponse = z.infer<typeof OpenImportResponseSchema>;

/**
 * One item of `GET /v1/imports`. `first_day` and `last_day` are the UTC dates of the earliest and latest `ts` of the
 * import's accepted observations (the days the recordings show), null until one is accepted.
 */
export const ImportSchema = z.strictObject({
  id: uuid,
  source_kind: ImportSourceKindSchema,
  first_day: day.nullable(),
  last_day: day.nullable(),
  created_at: rfc3339,
});
export type Import = z.infer<typeof ImportSchema>;

export const FORGET_SCOPES = ["entity", "range", "all", "import"] as const;
export type ForgetScope = (typeof FORGET_SCOPES)[number];

/** `POST /v1/me/forget` body. Scope `import` (M3) needs `import_id`; the other scopes arrive in M7. */
export const ForgetRequestSchema = z.strictObject({
  scope: z.enum(FORGET_SCOPES),
  entity_id: uuid.optional(),
  from: day.optional(),
  to: day.optional(),
  import_id: uuid.optional(),
});
export type ForgetRequest = z.infer<typeof ForgetRequestSchema>;

/** `POST /v1/me/forget` answer (202). */
export const ForgetResponseSchema = z.strictObject({ purge_request_id: uuid });
export type ForgetResponse = z.infer<typeof ForgetResponseSchema>;

export const PURGE_STATES = ["queued", "running", "done", "failed"] as const;
/** `GET /v1/purge-requests/{id}` answer. */
export const PurgeRequestStateSchema = z.strictObject({ state: z.enum(PURGE_STATES) });
export type PurgeRequestState = z.infer<typeof PurgeRequestStateSchema>;
