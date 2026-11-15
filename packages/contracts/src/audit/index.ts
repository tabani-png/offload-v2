import { z } from "zod";
import { hex64, nonNegativeInt, rfc3339, ulid } from "../primitives.ts";

/**
 * Audit contracts (ADR 0018, docs/API.md "Metrics, audit and policy"). m2-12-audit-anchors.
 * `tenant_id` is not in the event shape: the route is already scoped to the caller's tenant.
 */

export const AuditEventSchema = z.strictObject({
  seq: z.number().int().min(1).max(Number.MAX_SAFE_INTEGER),
  id: ulid,
  at: rfc3339,
  principal_id: z.string().regex(/^[A-Za-z0-9_:.-]{1,128}$/),
  action: z.string().regex(/^[a-z_]+\.[a-z_]+$/),
  subject_type: z.string().nullable(),
  subject_id: z.string().nullable(),
  rule_id: z.string().nullable(),
  /** Ids and hashes only. */
  details: z.record(z.string(), z.unknown()),
  prev_hash: hex64,
  hash: hex64,
});
export type AuditEvent = z.infer<typeof AuditEventSchema>;

export const AUDIT_VERIFY_REASONS = ["hash_mismatch", "seq_gap", "prev_hash_mismatch", "anchor_mismatch", "anchor_signature"] as const;
export const AuditVerifyReasonSchema = z.enum(AUDIT_VERIFY_REASONS);
export type AuditVerifyReason = z.infer<typeof AuditVerifyReasonSchema>;

export const AuditVerifyResultSchema = z.strictObject({
  ok: z.boolean(),
  checked: nonNegativeInt,
  first_bad_seq: z.number().int().min(1).max(Number.MAX_SAFE_INTEGER).optional(),
  reason: AuditVerifyReasonSchema.optional(),
});
export type AuditVerifyResult = z.infer<typeof AuditVerifyResultSchema>;

export const AuditEventListSchema = z.strictObject({
  items: z.array(AuditEventSchema).max(200),
  /** Pass back as `cursor` for the next older page; null on the last page. */
  next_cursor: z.string().regex(/^[0-9]{1,15}$/).nullable(),
});
export type AuditEventList = z.infer<typeof AuditEventListSchema>;
