import { z } from "zod";
import { rfc3339, uuid } from "../primitives.ts";

/**
 * Auth and device contracts (ADR 0014, docs/API.md "Auth and me" and "Devices"). m1-04-login-devices.
 * Shapes of the request and response bodies; the server validates every body with these.
 */

/** 32 random bytes, base64url without padding (session tokens, csrf tokens, codes, nonces, magic link tokens). */
export const token32 = z.string().regex(/^[A-Za-z0-9_-]{43}$/);
const b64url = z.string().regex(/^[A-Za-z0-9_-]+$/);

export const DEVICE_TOKEN_AUDIENCES = ["device", "member"] as const;
export const DeviceTokenAudienceSchema = z.enum(DEVICE_TOKEN_AUDIENCES);
export type DeviceTokenAudience = z.infer<typeof DeviceTokenAudienceSchema>;

export const KEY_STORAGES = ["secure_enclave", "keychain"] as const;
export const KeyStorageSchema = z.enum(KEY_STORAGES);

/**
 * A P-256 public key as a JWK: kty EC, crv P-256, x and y of 32 bytes each, no private part (`d`). Extra public
 * members (`kid`, `alg`, `use`) are allowed and dropped when stored. Whether the point is on the curve is checked by
 * importing the key (services/api).
 */
export const P256PublicJwkSchema = z
  .looseObject({
    kty: z.literal("EC"),
    crv: z.literal("P-256"),
    x: z.string().regex(/^[A-Za-z0-9_-]{43}$/),
    y: z.string().regex(/^[A-Za-z0-9_-]{43}$/),
  })
  .refine((j) => !("d" in j), { message: "public_jwk must not hold a private key" });
export type P256PublicJwk = { kty: "EC"; crv: "P-256"; x: string; y: string };

export const MagicLinkRequestSchema = z.strictObject({
  email: z.email().max(254),
  /** Same-origin path to land on after login; default "/". */
  return_to: z.string().max(2048).optional(),
});

/** RFC 7636 code verifier: 43 to 128 unreserved characters. */
export const codeVerifier = z.string().regex(/^[A-Za-z0-9._~-]{43,128}$/);

export const DeviceEnrollRequestSchema = z.strictObject({
  code: token32,
  code_verifier: codeVerifier,
  redirect_uri: z.string().max(64),
  public_jwk: z.record(z.string(), z.unknown()),
  name: z.string().min(1).max(128),
  key_storage: KeyStorageSchema,
});
export const DeviceEnrollResponseSchema = z.strictObject({ device_id: uuid });

export const DeviceChallengeRequestSchema = z.strictObject({ device_id: uuid, audience: DeviceTokenAudienceSchema });
export const DeviceChallengeResponseSchema = z.strictObject({ nonce: token32, expires_at: rfc3339 });

export const DeviceTokenRequestSchema = z.strictObject({
  device_id: uuid,
  nonce: token32,
  /** base64url (no padding) of the 64-byte raw r‖s over the UTF-8 of `nonce`. */
  signature: b64url.max(128),
});
export const DeviceTokenResponseSchema = z.strictObject({ token: z.string(), expires_at: rfc3339 });

/** Device token claims (ES256 JWT, 15 minutes). */
export const DeviceTokenClaimsSchema = z.looseObject({
  aud: DeviceTokenAudienceSchema,
  tenant_id: uuid,
  member_id: uuid,
  device_id: uuid,
  iat: z.number().int(),
  exp: z.number().int(),
});

export const DeviceSchema = z.strictObject({
  id: uuid,
  member_id: uuid,
  name: z.string(),
  key_storage: KeyStorageSchema,
  enrolled_at: rfc3339,
  revoked_at: rfc3339.nullable(),
});
export type Device = z.infer<typeof DeviceSchema>;

export const TENANT_ROLES = ["owner", "admin", "member", "auditor"] as const;

export const MeResponseSchema = z.strictObject({
  member: z.strictObject({
    id: uuid,
    email: z.string(),
    display_name: z.string().nullable(),
    tenant_role: z.enum(TENANT_ROLES),
    state: z.string(),
  }),
  tenant: z.strictObject({
    id: uuid,
    kind: z.enum(["personal", "team"]),
    name: z.string(),
    plan: z.enum(["free", "pro", "enterprise"]),
    reporting_timezone: z.string(),
  }),
  workspaces: z.array(z.strictObject({ id: uuid, name: z.string(), workspace_role: z.enum(["lead", "member"]) })),
  tenant_role: z.enum(TENANT_ROLES),
  features: z.array(z.string()),
  /** Web sessions only, on the first GET /v1/me of the session. */
  csrf_token: token32.optional(),
});
export type MeResponse = z.infer<typeof MeResponseSchema>;
