import { webcrypto } from "node:crypto";
import { P256PublicJwkSchema, jcs, type P256PublicJwk } from "@offload/contracts";

/**
 * Device signatures, one rule everywhere (ADR 0014, docs/API.md "Signatures"): ECDSA P-256 / SHA-256, the signature
 * is the 64-byte raw r‖s (JOSE / IEEE P1363, Swift `ECDSASignature.rawRepresentation`), base64url without padding.
 * DER (Swift `derRepresentation`) is refused. Used by POST /v1/devices/token (signed bytes = UTF-8 of the nonce) and,
 * from M2, by Mac approvals (`Offload-Signature`, signed bytes = the exact JCS request body).
 */

const RAW_SIG_B64URL = /^[A-Za-z0-9_-]{86}$/; // 64 bytes, no padding

/** The public part of a P-256 JWK, or null when it is not one (wrong curve, private part, bad coordinates). */
export async function parseP256PublicJwk(jwk: unknown): Promise<P256PublicJwk | null> {
  const parsed = P256PublicJwkSchema.safeParse(jwk);
  if (!parsed.success) return null;
  const pub: P256PublicJwk = { kty: "EC", crv: "P-256", x: parsed.data.x, y: parsed.data.y };
  return (await importP256(pub)) ? pub : null;
}

async function importP256(jwk: P256PublicJwk): Promise<CryptoKey | null> {
  try {
    // Import validates that the point is on the curve.
    return await webcrypto.subtle.importKey("jwk", { ...jwk, ext: true }, { name: "ECDSA", namedCurve: "P-256" }, false, ["verify"]);
  } catch {
    return null;
  }
}

/** True when `sig` is a valid raw r‖s P-256 signature over `bytes` by `publicJwk`. Never throws. */
export async function verifyDeviceSignature(publicJwk: unknown, bytes: Uint8Array, sig: string): Promise<boolean> {
  if (typeof sig !== "string" || !RAW_SIG_B64URL.test(sig)) return false;
  const raw = Buffer.from(sig, "base64url");
  if (raw.length !== 64 || raw.toString("base64url") !== sig) return false;
  const parsed = P256PublicJwkSchema.safeParse(publicJwk);
  if (!parsed.success) return false;
  const key = await importP256({ kty: "EC", crv: "P-256", x: parsed.data.x, y: parsed.data.y });
  if (!key) return false;
  try {
    return await webcrypto.subtle.verify({ name: "ECDSA", hash: "SHA-256" }, key, raw, new Uint8Array(bytes));
  } catch {
    return false;
  }
}

const UUID = "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}";
const HEADER_RE = new RegExp(`^keyid=(${UUID}),[ ]?sig=([A-Za-z0-9_-]{1,128})$`);

/** `Offload-Signature: keyid=<device_id>, sig=<base64url>` → its parts, or null when malformed. */
export function parseOffloadSignature(header: string | null | undefined): { keyid: string; sig: string } | null {
  if (typeof header !== "string") return null;
  const m = HEADER_RE.exec(header.trim());
  return m ? { keyid: m[1]!, sig: m[2]! } : null;
}

/** A signed body must be exactly its own JCS form (else 400 invalid_request). */
export function isCanonicalBody(rawBody: string): boolean {
  try {
    return jcs(JSON.parse(rawBody)) === rawBody;
  } catch {
    return false;
  }
}

export type SignedBodyResult = { ok: true } | { ok: false; code: "invalid_request" | "unauthenticated" };

/**
 * Checks a device-signed request body: header well formed and naming `deviceId`, body in JCS form, signature valid.
 * For Mac approvals (M2); the caller has already resolved the device and its key.
 */
export async function verifySignedBody(input: {
  header: string | null | undefined; rawBody: string; deviceId: string; publicJwk: unknown;
}): Promise<SignedBodyResult> {
  const h = parseOffloadSignature(input.header);
  if (!h || h.keyid !== input.deviceId) return { ok: false, code: "unauthenticated" };
  if (!isCanonicalBody(input.rawBody)) return { ok: false, code: "invalid_request" };
  const ok = await verifyDeviceSignature(input.publicJwk, new TextEncoder().encode(input.rawBody), h.sig);
  return ok ? { ok: true } : { ok: false, code: "unauthenticated" };
}
