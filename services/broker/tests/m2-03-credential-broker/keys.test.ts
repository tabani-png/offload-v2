import { afterAll, beforeAll, expect, test } from "bun:test";
import { existsSync, mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { randomBytes } from "node:crypto";
import { uuidv7 } from "@offload/db";
import { FakeKms } from "@offload/testkit/src/broker/index.ts";
import { awsKmsKeyProvider } from "../../src/keys/aws-kms.ts";
import { localKeyProvider } from "../../src/keys/local.ts";
import { startFromEnv } from "../../src/start.ts";
import { SERVICE_TOKEN, writeKeyFile } from "./harness.ts";
import { Vault } from "../../src/vault/vault.ts";
import { createLogger } from "../../src/log.ts";
import { FakeClock } from "@offload/testkit/src/auth.ts";

let dir: string;
beforeAll(() => {
  dir = mkdtempSync(join(tmpdir(), "offload-keys-"));
});
afterAll(() => rmSync(dir, { recursive: true, force: true }));

test("KEY: the local provider refuses a master key file readable by group or others", async () => {
  for (const [i, mode] of [0o640, 0o604, 0o644, 0o660].entries()) {
    const path = writeKeyFile(dir, randomBytes(32), mode, `loose-${i}.key`);
    expect(() => localKeyProvider(path)).toThrow(/group or other|permission/i);
  }
  // Nothing listens: the whole start fails before the socket is created.
  const loose = writeKeyFile(dir, randomBytes(32), 0o644, "loose-start.key");
  const tokenFile = writeKeyFile(dir, Buffer.from(SERVICE_TOKEN), 0o600, "token");
  const socket = join(dir, "never.sock");
  await expect(
    startFromEnv({
      OFFLOAD_KEY_PROVIDER: "local", OFFLOAD_MASTER_KEY_FILE: loose, OFFLOAD_BROKER_SOCKET: socket,
      OFFLOAD_BROKER_SERVICE_TOKEN_REF: tokenFile, DATABASE_URL: "postgres://nobody@127.0.0.1:1/none",
    }),
  ).rejects.toThrow();
  expect(existsSync(socket)).toBe(false);
  // Control: the same file with mode 0600 loads.
  expect(localKeyProvider(writeKeyFile(dir, randomBytes(32), 0o600, "ok.key")).name).toBe("local");
});

test("KEY: the local provider refuses a key file that is not exactly 32 bytes", () => {
  for (const n of [0, 16, 31, 33, 64]) {
    expect(() => localKeyProvider(writeKeyFile(dir, randomBytes(n), 0o600, `len-${n}.key`))).toThrow(/32 bytes/);
  }
  expect(() => localKeyProvider(join(dir, "missing.key"))).toThrow();
});

test("KEY: a data key wrapped for tenant A does not unwrap for tenant B", async () => {
  const a = uuidv7();
  const b = uuidv7();
  const providers = [localKeyProvider(writeKeyFile(dir, randomBytes(32), 0o600, "ab.key")), awsKmsKeyProvider(new FakeKms("k1"), "k1")];
  for (const p of providers) {
    const dek = randomBytes(32);
    const wrapped = await p.wrap(dek, { tenant_id: a });
    expect(Buffer.from(wrapped).includes(dek)).toBe(false);
    expect(Buffer.from(await p.unwrap(wrapped, { tenant_id: a })).equals(dek)).toBe(true);
    await expect(p.unwrap(wrapped, { tenant_id: b })).rejects.toThrow();
  }
});

test("KEY: aws-kms sends the configured key id and tenant_id as the encryption context", async () => {
  const kms = new FakeKms("arn:aws:kms:ca-central-1:000000000000:key/test");
  const p = awsKmsKeyProvider(kms, "arn:aws:kms:ca-central-1:000000000000:key/test");
  const tenant = uuidv7();
  const wrapped = await p.wrap(randomBytes(32), { tenant_id: tenant });
  await p.unwrap(wrapped, { tenant_id: tenant });
  expect(kms.calls.map((c) => c.op)).toEqual(["generateDataKey", "decrypt"]);
  for (const c of kms.calls) {
    expect(c.keyId).toBe("arn:aws:kms:ca-central-1:000000000000:key/test");
    expect(c.encryptionContext).toEqual({ tenant_id: tenant });
  }
  expect(p.name).toBe("aws-kms");
  expect(p.keyRef).toBe("arn:aws:kms:ca-central-1:000000000000:key/test");
});

test("KEY: a credential row from another key provider fails closed", async () => {
  const { setup, connect, credentialRow } = await import("./harness.ts");
  const env = await setup({ keys: "local" });
  try {
    const conn = await connect(env, env.fx.a);
    await env.broker.vault.put(env.fx.a.tenantId, conn, { kind: "api_key", api_key: "stored-with-local-provider" }, { scopes: [], expiresAt: null });
    expect((await credentialRow(env, env.fx.a, conn)).key_provider).toBe("local");
    // The same database read through a broker configured for aws-kms.
    const kms = new FakeKms("k2");
    const other = new Vault({ pool: env.pool, keys: awsKmsKeyProvider(kms, "k2"), clock: new FakeClock(), logger: createLogger(() => {}) });
    await expect(other.get(env.fx.a.tenantId, conn)).rejects.toMatchObject({ code: "key_provider_mismatch" });
    expect(kms.calls).toEqual([]); // nothing was unwrapped
    // A different key_ref under the same provider name fails closed too.
    await env.fx.admin.query("update credentials set key_ref = 'local:another' where tenant_id = $1 and connection_id = $2", [env.fx.a.tenantId, conn]);
    await expect(env.broker.vault.get(env.fx.a.tenantId, conn)).rejects.toMatchObject({ code: "key_provider_mismatch" });
  } finally {
    await env.stop();
  }
});
