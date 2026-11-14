import { z } from "zod";

/** The closed list from docs/API.md ("Error envelope"), grouped by HTTP status. A test compares it to the doc. */
export const ERROR_CODES_BY_STATUS = {
  400: ["invalid_request", "unknown_kind", "schema_invalid", "clock_skew"],
  401: ["unauthenticated", "token_expired"],
  403: ["forbidden", "policy_denied", "feature_not_licensed", "hash_mismatch", "consent_missing"],
  404: ["not_found"],
  409: ["already_running", "approval_used", "approval_expired", "idempotency_conflict", "seq_replay", "nonce_used", "last_owner", "state_conflict", "stale_notice"],
  413: ["too_large"],
  422: ["leak_detected", "teeth_gate_failed", "budget_exceeded", "recipient_not_allowed"],
  429: ["rate_limited"],
  500: ["server_error"],
} as const;

export const ERROR_CODES = [
  "invalid_request", "unknown_kind", "schema_invalid", "clock_skew",
  "unauthenticated", "token_expired",
  "forbidden", "policy_denied", "feature_not_licensed", "hash_mismatch", "consent_missing",
  "not_found",
  "already_running", "approval_used", "approval_expired", "idempotency_conflict", "seq_replay", "nonce_used", "last_owner", "state_conflict", "stale_notice",
  "too_large",
  "leak_detected", "teeth_gate_failed", "budget_exceeded", "recipient_not_allowed",
  "rate_limited",
  "server_error",
] as const;
export type ErrorCode = (typeof ERROR_CODES)[number];

/** `req_` + ULID. */
export const requestId = z.string().regex(/^req_[0-9A-HJKMNP-TV-Z]{26}$/);

export const ErrorEnvelopeSchema = z.strictObject({
  error: z.strictObject({
    code: z.enum(ERROR_CODES),
    message: z.string().max(1024),
    request_id: requestId,
    /** Present only when a policy decided. */
    rule_id: z.string().min(1).max(128).optional(),
  }),
});
export type ErrorEnvelope = z.infer<typeof ErrorEnvelopeSchema>;
