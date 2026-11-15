import { createCipheriv, createDecipheriv, randomBytes } from "node:crypto";
import type { KmsClient } from "@offload/contracts/src/broker/index.ts";

/**
 * FakeKms: an in-memory KmsClient (m2-03). Enforces the key id and the encryption context exactly as AWS KMS does (a
 * Decrypt with another context or key id fails), and records every call so a test can assert what was sent.
 */

export interface KmsCall {
  op: "generateDataKey" | "decrypt";
  keyId: string;
  encryptionContext: Record<string, string>;
}

export class FakeKms implements KmsClient {
  readonly calls: KmsCall[] = [];
  readonly #master = randomBytes(32);
  constructor(readonly keyId: string = "fake-key-id") {}

  get decrypts(): KmsCall[] {
    return this.calls.filter((c) => c.op === "decrypt");
  }

  #aad(ctx: Record<string, string>): Buffer {
    return Buffer.from(JSON.stringify(Object.keys(ctx).sort().map((k) => [k, ctx[k]])), "utf8");
  }

  async generateDataKey(input: { keyId: string; encryptionContext: Record<string, string> }) {
    this.calls.push({ op: "generateDataKey", keyId: input.keyId, encryptionContext: { ...input.encryptionContext } });
    if (input.keyId !== this.keyId) throw new Error("FakeKms: NotFoundException (unknown key id)");
    const plaintext = randomBytes(32);
    const nonce = randomBytes(12);
    const c = createCipheriv("aes-256-gcm", this.#master, nonce);
    c.setAAD(this.#aad(input.encryptionContext));
    const ct = Buffer.concat([c.update(plaintext), c.final()]);
    return { plaintext: new Uint8Array(plaintext), ciphertextBlob: new Uint8Array(Buffer.concat([nonce, ct, c.getAuthTag()])) };
  }

  async decrypt(input: { keyId: string; ciphertextBlob: Uint8Array; encryptionContext: Record<string, string> }) {
    this.calls.push({ op: "decrypt", keyId: input.keyId, encryptionContext: { ...input.encryptionContext } });
    if (input.keyId !== this.keyId) throw new Error("FakeKms: IncorrectKeyException (key id)");
    const b = Buffer.from(input.ciphertextBlob);
    try {
      const d = createDecipheriv("aes-256-gcm", this.#master, b.subarray(0, 12));
      d.setAAD(this.#aad(input.encryptionContext));
      d.setAuthTag(b.subarray(b.length - 16));
      return { plaintext: new Uint8Array(Buffer.concat([d.update(b.subarray(12, b.length - 16)), d.final()])) };
    } catch {
      throw new Error("FakeKms: InvalidCiphertextException (encryption context does not match)");
    }
  }
}
