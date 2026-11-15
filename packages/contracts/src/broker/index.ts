import { z } from "zod";
import { hex64 } from "../primitives.ts";

/**
 * Credential broker protocol (ADR 0034, slice m2-03-credential-broker): JSON over HTTP on a Unix socket, spoken only
 * between TypeScript processes, so no JSON Schema is generated. Not re-exported from the package barrel: import by
 * subpath (`@offload/contracts/src/broker/index.ts`).
 *
 * No response shape holds a credential. `api_key` and `code` are write-only (request side).
 */

const LOWER_UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
export const lowerUuid = z.string().regex(LOWER_UUID);
const providerSlug = z.string().regex(/^[a-z][a-z0-9_]{0,63}$/);
const capability = z.string().regex(/^[A-Za-z0-9_.:-]{1,128}$/);
const scope = z.string().min(1).max(256);

export const OAuthBeginRequestSchema = z.object({
  tenant_id: lowerUuid,
  member_id: lowerUuid,
  connection_id: lowerUuid,
  provider: providerSlug,
  scopes: z.array(scope).max(64),
  redirect_uri: z.string().url().max(2048),
});
export type OAuthBeginRequest = z.infer<typeof OAuthBeginRequestSchema>;
export const OAuthBeginResponseSchema = z.strictObject({ authorize_url: z.string().url() });

export const OAuthFinishRequestSchema = z.object({
  tenant_id: lowerUuid,
  state: z.string().min(16).max(256),
  code: z.string().min(1).max(4096),
});
export type OAuthFinishRequest = z.infer<typeof OAuthFinishRequestSchema>;
export const OAuthFinishResponseSchema = z.strictObject({
  connection_id: lowerUuid,
  account_label: z.string().max(256),
  account_hash: hex64,
  scopes: z.array(scope),
});

export const ApiKeyRequestSchema = z.object({
  tenant_id: lowerUuid,
  connection_id: lowerUuid,
  api_key: z.string().min(1).max(4096),
});
export type ApiKeyRequest = z.infer<typeof ApiKeyRequestSchema>;
export const ApiKeyResponseSchema = z.strictObject({ account_label: z.string().max(256), account_hash: hex64 });

export const ShredRequestSchema = z.object({ tenant_id: lowerUuid, connection_id: lowerUuid });
export type ShredRequest = z.infer<typeof ShredRequestSchema>;

export const ToolsListRequestSchema = z.object({ tenant_id: lowerUuid, connection_id: lowerUuid });
export type ToolsListRequest = z.infer<typeof ToolsListRequestSchema>;
export const ToolsListResponseSchema = z.strictObject({ tools: z.array(z.record(z.string(), z.unknown())) });

export const CALL_KINDS = ["read", "commit"] as const;
export const GATE_MODES = ["read", "live"] as const;

export const OutboundRequestSchema = z.object({
  method: z.enum(["GET", "POST", "PUT", "PATCH", "DELETE"]),
  url: z.string().url().max(4096),
  headers: z.record(z.string(), z.string()).default({}),
  body: z.string().max(8_000_000).nullish(),
});
export type OutboundRequest = z.infer<typeof OutboundRequestSchema>;

/**
 * A caller-supplied `item_hash` is not part of this shape: unknown keys are dropped, and the broker computes
 * sha256Hex(jcs(arguments)) itself.
 */
export const CallRequestSchema = z.object({
  tenant_id: lowerUuid,
  kind: z.enum(CALL_KINDS),
  gate_mode: z.enum(GATE_MODES),
  connection_id: lowerUuid,
  capability,
  arguments: z.unknown(),
  run_id: lowerUuid.optional(),
  fixture_set_id: lowerUuid.optional(),
  approval_id: lowerUuid.optional(),
  request: OutboundRequestSchema,
});
export type CallRequest = z.infer<typeof CallRequestSchema>;
export const CallResponseSchema = z.strictObject({
  status: z.number().int(),
  headers: z.record(z.string(), z.string()),
  body: z.string(),
});
export type CallResponse = z.infer<typeof CallResponseSchema>;

/**
 * Codes the broker answers with. `PUBLIC` ones are in docs/API.md and keep its status; `BROKER_ONLY` ones never reach a
 * public response (the API maps them).
 */
export const BROKER_PUBLIC_CODES = {
  invalid_request: 400,
  unauthenticated: 401,
  forbidden: 403,
  hash_mismatch: 403,
  not_found: 404,
  approval_used: 409,
  approval_expired: 409,
  state_conflict: 409,
  server_error: 500,
} as const;
export const BROKER_ONLY_CODES = {
  read_not_declared: 403,
  gate_read_only: 403,
  host_not_allowed: 403,
  key_provider_mismatch: 500,
  upstream_unreachable: 502,
  oauth_exchange_failed: 502,
} as const;
export const BROKER_ERROR_STATUS = { ...BROKER_PUBLIC_CODES, ...BROKER_ONLY_CODES } as const;
export type BrokerErrorCode = keyof typeof BROKER_ERROR_STATUS;

export const BrokerErrorEnvelopeSchema = z.strictObject({
  error: z.strictObject({
    code: z.enum(Object.keys(BROKER_ERROR_STATUS) as [BrokerErrorCode, ...BrokerErrorCode[]]),
    message: z.string().max(512),
  }),
});
export type BrokerErrorEnvelope = z.infer<typeof BrokerErrorEnvelopeSchema>;

// ---- ports (their Postgres implementations land with the tables they read: m2-04, m2-06, m2-10) ----

/** What the approval check says about an item hash. */
export type ApprovalVerdict = "ok" | "hash_mismatch" | "forbidden" | "approval_used" | "approval_expired";

export interface ApprovalVerifier {
  check(tenantId: string, approvalId: string, itemHash: string): Promise<ApprovalVerdict>;
}

export interface RunScopeSource {
  /** Capabilities the run's routine version declared it reads; null when the run is unknown. */
  readSet(tenantId: string, runId: string): Promise<string[] | null>;
  /** Capabilities a fixture capture set may read; null when the set is unknown. */
  fixtureScope(tenantId: string, fixtureSetId: string): Promise<string[] | null>;
}

/** The AWS KMS calls the broker needs; the real one is services/broker/src/keys/aws-kms-client.ts. */
export interface KmsClient {
  generateDataKey(input: { keyId: string; encryptionContext: Record<string, string> }): Promise<{ plaintext: Uint8Array; ciphertextBlob: Uint8Array }>;
  decrypt(input: { keyId: string; ciphertextBlob: Uint8Array; encryptionContext: Record<string, string> }): Promise<{ plaintext: Uint8Array }>;
}

/** Wraps and unwraps a data key. `ctx.tenant_id` is bound into every wrap (AAD or KMS encryption context). */
export interface KeyProvider {
  readonly name: "local" | "aws-kms";
  readonly keyRef: string;
  wrap(dek: Uint8Array, ctx: { tenant_id: string }): Promise<Uint8Array>;
  unwrap(wrapped: Uint8Array, ctx: { tenant_id: string }): Promise<Uint8Array>;
}
