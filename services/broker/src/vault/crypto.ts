import { createCipheriv, createDecipheriv, randomBytes } from "node:crypto";

/** AES-256-GCM with a random 12-byte nonce. AAD = tenant_id || 0x00 || connection_id binds a ciphertext to its row. */

export function aadFor(tenantId: string, connectionId: string): Buffer {
  return Buffer.concat([Buffer.from(tenantId, "utf8"), Buffer.from([0]), Buffer.from(connectionId, "utf8")]);
}

export function newDataKey(): Buffer {
  return randomBytes(32);
}

export function seal(dek: Uint8Array, plaintext: Uint8Array, aad: Buffer): { ciphertext: Buffer; nonce: Buffer } {
  const nonce = randomBytes(12);
  const c = createCipheriv("aes-256-gcm", dek, nonce);
  c.setAAD(aad);
  const ct = Buffer.concat([c.update(plaintext), c.final()]);
  return { ciphertext: Buffer.concat([ct, c.getAuthTag()]), nonce };
}

/** Throws when the tag does not verify (wrong key, wrong AAD, tampered ciphertext). */
export function open(dek: Uint8Array, ciphertext: Uint8Array, nonce: Uint8Array, aad: Buffer): Buffer {
  const b = Buffer.from(ciphertext);
  if (b.length < 16) throw new Error("ciphertext is malformed");
  const d = createDecipheriv("aes-256-gcm", dek, nonce);
  d.setAAD(aad);
  d.setAuthTag(b.subarray(b.length - 16));
  return Buffer.concat([d.update(b.subarray(0, b.length - 16)), d.final()]);
}
