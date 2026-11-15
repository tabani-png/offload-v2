import { createCipheriv, createDecipheriv, randomBytes } from "node:crypto";
import type { KeyProvider, KmsClient } from "@offload/contracts/src/broker/index.ts";

/**
 * The `aws-kms` key provider (ADR 0034): GenerateDataKey (AES_256) and Decrypt through a KmsClient with
 * KeyId = OFFLOAD_KMS_KEY_REF and EncryptionContext = { tenant_id }.
 *
 * The port wraps a data key the vault already made. KMS generates its own keys, so each wrap asks KMS for a fresh
 * AES_256 data key, uses its plaintext as a one-time wrapping key for the vault's data key (AES-256-GCM, AAD =
 * tenant_id) and stores the KMS ciphertext blob next to it: wrapped = u16 blobLength || blob || nonce || ct || tag.
 * Unwrap asks KMS to Decrypt the blob under the same encryption context. Only the KMS key can open a wrapped key.
 */
export function awsKmsKeyProvider(client: KmsClient, keyRef: string): KeyProvider {
  const ctxOf = (ctx: { tenant_id: string }) => ({ tenant_id: ctx.tenant_id });
  const aad = (ctx: { tenant_id: string }) => Buffer.from(ctx.tenant_id, "utf8");
  return {
    name: "aws-kms",
    keyRef,
    async wrap(dek, ctx) {
      const { plaintext, ciphertextBlob } = await client.generateDataKey({ keyId: keyRef, encryptionContext: ctxOf(ctx) });
      const wrappingKey = Buffer.from(plaintext);
      try {
        const nonce = randomBytes(12);
        const c = createCipheriv("aes-256-gcm", wrappingKey, nonce);
        c.setAAD(aad(ctx));
        const ct = Buffer.concat([c.update(dek), c.final()]);
        const len = Buffer.alloc(2);
        len.writeUInt16BE(ciphertextBlob.length);
        return new Uint8Array(Buffer.concat([len, Buffer.from(ciphertextBlob), nonce, ct, c.getAuthTag()]));
      } finally {
        wrappingKey.fill(0);
      }
    },
    async unwrap(wrapped, ctx) {
      const b = Buffer.from(wrapped);
      if (b.length < 2) throw new Error("wrapped data key is malformed");
      const n = b.readUInt16BE(0);
      if (b.length < 2 + n + 12 + 16) throw new Error("wrapped data key is malformed");
      const blob = b.subarray(2, 2 + n);
      const rest = b.subarray(2 + n);
      const { plaintext } = await client.decrypt({ keyId: keyRef, ciphertextBlob: new Uint8Array(blob), encryptionContext: ctxOf(ctx) });
      const wrappingKey = Buffer.from(plaintext);
      try {
        const d = createDecipheriv("aes-256-gcm", wrappingKey, rest.subarray(0, 12));
        d.setAAD(aad(ctx));
        d.setAuthTag(rest.subarray(rest.length - 16));
        return new Uint8Array(Buffer.concat([d.update(rest.subarray(12, rest.length - 16)), d.final()]));
      } finally {
        wrappingKey.fill(0);
      }
    },
  };
}
