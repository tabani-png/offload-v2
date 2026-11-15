import { createCipheriv, createDecipheriv, createHmac, randomBytes } from "node:crypto";
import { readFileSync, statSync } from "node:fs";
import type { KeyProvider } from "@offload/contracts/src/broker/index.ts";

/**
 * The `local` key provider (ADR 0034): a 32-byte master key read from OFFLOAD_MASTER_KEY_FILE, for self-host with only
 * Postgres. Refused at start unless the file is exactly 32 bytes, owned by the process user and has no group or other
 * permission bits. Wrap = AES-256-GCM, random 12-byte nonce, AAD = tenant_id; wrapped = nonce || ciphertext || tag.
 */

export class KeyFileError extends Error {
  readonly code = "key_file_invalid";
  constructor(message: string) {
    super(message);
    this.name = "KeyFileError";
  }
}

export function localKeyProvider(masterKeyFile: string): KeyProvider {
  let st;
  try {
    st = statSync(masterKeyFile);
  } catch {
    throw new KeyFileError("master key file cannot be read");
  }
  if (!st.isFile()) throw new KeyFileError("master key path is not a regular file");
  if (typeof process.getuid === "function" && st.uid !== process.getuid()) throw new KeyFileError("master key file is not owned by the broker's OS user");
  if ((st.mode & 0o077) !== 0) throw new KeyFileError("master key file has group or other permission bits: chmod 600");
  const key = readFileSync(masterKeyFile);
  if (key.length !== 32) throw new KeyFileError("master key file must be exactly 32 bytes");
  // A stable fingerprint that does not reveal the key, so a row says which key wrapped it.
  const keyRef = `local:${createHmac("sha256", key).update("offload-key-ref").digest("hex").slice(0, 16)}`;
  const aad = (ctx: { tenant_id: string }) => Buffer.from(ctx.tenant_id, "utf8");
  return {
    name: "local",
    keyRef,
    async wrap(dek, ctx) {
      const nonce = randomBytes(12);
      const c = createCipheriv("aes-256-gcm", key, nonce);
      c.setAAD(aad(ctx));
      const ct = Buffer.concat([c.update(dek), c.final()]);
      return new Uint8Array(Buffer.concat([nonce, ct, c.getAuthTag()]));
    },
    async unwrap(wrapped, ctx) {
      const b = Buffer.from(wrapped);
      if (b.length < 12 + 16) throw new Error("wrapped data key is malformed");
      const d = createDecipheriv("aes-256-gcm", key, b.subarray(0, 12));
      d.setAAD(aad(ctx));
      d.setAuthTag(b.subarray(b.length - 16));
      return new Uint8Array(Buffer.concat([d.update(b.subarray(12, b.length - 16)), d.final()]));
    },
  };
}
