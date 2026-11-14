import { createHash, randomBytes, timingSafeEqual } from "node:crypto";

/** 32 random bytes, base64url without padding (43 characters). */
export function random32(): string {
  return randomBytes(32).toString("base64url");
}

export function sha256Hex(s: string): string {
  return createHash("sha256").update(s).digest("hex");
}

/** RFC 7636 S256: base64url(sha256(ASCII(verifier))). */
export function s256(verifier: string): string {
  return createHash("sha256").update(verifier, "ascii").digest("base64url");
}

/** Constant-time string equality (lengths may differ). */
export function safeEqual(a: string, b: string): boolean {
  const x = Buffer.from(a);
  const y = Buffer.from(b);
  return x.length === y.length && timingSafeEqual(x, y);
}
