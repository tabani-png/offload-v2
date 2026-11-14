import { z } from "zod";
import { sha256Hex } from "./hash.ts";
import { hasOnlyAllowedTokens } from "./pseudonym.ts";
import { hex16, hex64, nonNegativeInt, rfc3339, ulid, uuid } from "./primitives.ts";

/** Closed set (ADR 0020). `run_outcome`, `baseline_sample` and `daily_aggregate` are gone. */
export const UPLOAD_KINDS = ["observation_batch", "review_event", "notice_ack", "keyframe", "step_result"] as const;
export type UploadKind = (typeof UPLOAD_KINDS)[number];
export const UploadKindSchema = z.enum(UPLOAD_KINDS);

const noOtherTokens = { message: "contains an angle token that is not a pseudonym or a router placeholder" };
/** Masked free text: pseudonyms and router placeholders only. (JSON Schema carries the length, zod the token rule.) */
const maskedText = (max: number) => z.string().max(max).refine(hasOnlyAllowedTokens, noOtherTokens);

const docPseudonym = z.string().regex(/^<doc:h_[0-9a-f]{16}>$/);
/** Bare host: no scheme, no path, no port, no query. */
const host = z.string().min(1).max(253).regex(/^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)*$/);

const appBundleId = z.string().min(1).max(255);
const appName = z.string().min(1).max(256);
const perMinute = z.number().int().min(0).max(100000);

const base = {
  id: ulid,
  ts: rfc3339,
  source: z.enum(["live", "import"]).optional(),
  import_id: uuid.optional(),
};
const importRule = (o: { source?: "live" | "import" | undefined; import_id?: string | undefined }) => o.source !== "import" || o.import_id !== undefined;
const importMsg = { message: "import_id is required when source is import", path: ["import_id"] };

const FocusSchema = z
  .strictObject({
    ...base,
    kind: z.literal("focus"),
    app_bundle_id: appBundleId,
    app_name: appName,
    title: maskedText(512).optional(),
    host: host.optional(),
    doc: docPseudonym.optional(),
  })
  .refine(importRule, importMsg);
const IdleStartSchema = z.strictObject({ ...base, kind: z.literal("idle_start") }).refine(importRule, importMsg);
const IdleEndSchema = z.strictObject({ ...base, kind: z.literal("idle_end") }).refine(importRule, importMsg);
const InputCountsSchema = z
  .strictObject({ ...base, kind: z.literal("input_counts"), keys: perMinute, clicks: perMinute })
  .refine(importRule, importMsg);
const TextSnapshotSchema = z
  .strictObject({
    ...base,
    kind: z.literal("text_snapshot"),
    app_bundle_id: appBundleId,
    text: maskedText(8000),
    text_hash: hex64,
    text_source: z.enum(["ax", "ocr"]),
  })
  .refine(importRule, importMsg)
  .refine((o) => sha256Hex(o.text) === o.text_hash, { message: "text_hash must equal sha256Hex(text)", path: ["text_hash"] });
const pauseReason = z.enum(["user", "lock", "sleep", "permission"]);
const PauseSchema = z.strictObject({ ...base, kind: z.literal("pause"), reason: pauseReason }).refine(importRule, importMsg);
const ResumeSchema = z.strictObject({ ...base, kind: z.literal("resume"), reason: pauseReason }).refine(importRule, importMsg);
const PermissionChangeSchema = z
  .strictObject({
    ...base,
    kind: z.literal("permission_change"),
    perm: z.strictObject({ screen_recording: z.boolean(), accessibility: z.boolean() }),
  })
  .refine(importRule, importMsg);

export const OBSERVATION_KINDS = ["focus", "idle_start", "idle_end", "input_counts", "text_snapshot", "pause", "resume", "permission_change"] as const;

export const ObservationSchema = z.discriminatedUnion("kind", [
  FocusSchema, IdleStartSchema, IdleEndSchema, InputCountsSchema, TextSnapshotSchema, PauseSchema, ResumeSchema, PermissionChangeSchema,
]);
export type Observation = z.infer<typeof ObservationSchema>;

export const ReviewEventSchema = z.strictObject({
  id: ulid,
  ts: rfc3339,
  run_id: uuid,
  review_seconds: nonNegativeInt,
  edit_seconds: nonNegativeInt,
  fix_seconds: nonNegativeInt,
  items_edited: nonNegativeInt,
  decision: z.enum(["approved", "approved_with_edits", "rejected", "partial", "policy_committed"]),
  surface: z.literal("mac"),
});
export type ReviewEvent = z.infer<typeof ReviewEventSchema>;

export const NoticeAckSchema = z.strictObject({
  id: ulid,
  ts: rfc3339,
  notice_id: uuid,
  notice_version: z.string().min(1).max(32),
});
export type NoticeAck = z.infer<typeof NoticeAckSchema>;

export const KeyframeMetaSchema = z.strictObject({
  id: ulid,
  ts: rfc3339,
  phash: hex16,
  width: z.number().int().min(1).max(1280),
  height: z.number().int().min(1).max(100000),
  bytes: z.number().int().min(1).max(524288),
  sha256: hex64,
});
export type KeyframeMeta = z.infer<typeof KeyframeMetaSchema>;

export const StepResultSchema = z.strictObject({
  id: ulid,
  ts: rfc3339,
  command_id: uuid,
  item_hash: hex64,
  outcome: z.enum(["sent", "failed_before_send", "unknown"]),
  detail_code: z.string().min(1).max(64).optional(),
  finished_at: rfc3339,
});
export type StepResult = z.infer<typeof StepResultSchema>;

const envelopeBase = { v: z.literal(1), device_id: uuid, seq: nonNegativeInt, sent_at: rfc3339 };
const objects = <T extends z.ZodType>(item: T) => z.array(item).min(1).max(500);

/** `kind` selects the object schema. */
export const IngestEnvelopeSchema = z.discriminatedUnion("kind", [
  z.strictObject({ ...envelopeBase, kind: z.literal("observation_batch"), objects: objects(ObservationSchema) }),
  z.strictObject({ ...envelopeBase, kind: z.literal("review_event"), objects: objects(ReviewEventSchema) }),
  z.strictObject({ ...envelopeBase, kind: z.literal("notice_ack"), objects: objects(NoticeAckSchema) }),
  z.strictObject({ ...envelopeBase, kind: z.literal("keyframe"), objects: objects(KeyframeMetaSchema) }),
  z.strictObject({ ...envelopeBase, kind: z.literal("step_result"), objects: objects(StepResultSchema) }),
]);
export type IngestEnvelope = z.infer<typeof IngestEnvelopeSchema>;

export const RECEIPT_REJECTION_CODES = [
  "schema_invalid", "leak_detected", "excluded", "too_old", "unknown_kind", "consent_missing", "not_enabled", "rate_limited", "server_error",
] as const;
export type ReceiptRejectionCode = (typeof RECEIPT_REJECTION_CODES)[number];
/** Only these two may be resent unchanged. */
export const RETRYABLE_REJECTION_CODES: readonly ReceiptRejectionCode[] = ["rate_limited", "server_error"];

// An object whose own id was malformed can still be named in a receipt, so receipt ids are plain bounded strings.
const receiptId = z.string().min(1).max(64);
export const IngestReceiptSchema = z.strictObject({
  accepted: z.array(receiptId).max(500),
  rejected: z.array(z.strictObject({ id: receiptId, code: z.enum(RECEIPT_REJECTION_CODES) })).max(500),
});
export type IngestReceipt = z.infer<typeof IngestReceiptSchema>;

