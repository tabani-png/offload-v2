import { afterAll, beforeAll, expect, spyOn, test } from "bun:test";
import { createPublicKey, verify as edVerify } from "node:crypto";
import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { jcs } from "@offload/contracts";
import { pgTenantFixture, type PgTenantFixture } from "@offload/testkit";
import { fakeSigner } from "@offload/testkit/src/audit/index.ts";
import { fileSigner, verifyChain, withTenant, writeAnchor } from "../../src/index.ts";
import { appendN, newTenant } from "./helpers.ts";

let fx: PgTenantFixture;
beforeAll(async () => {
  fx = await pgTenantFixture({ appPoolSize: 6 });
});
afterAll(async () => {
  await fx?.close();
});

const anchors = async (tenantId: string) =>
  (await fx.admin.query("select * from audit_anchors where tenant_id = $1 order by seq", [tenantId])).rows;

test("ANCHOR: writeAnchor signs the JCS of tenant_id, seq, head_hash and signed_at", async () => {
  const signer = fakeSigner();
  const ctx = await newTenant(fx.app);
  await appendN(fx.app, ctx, 2);
  const now = new Date("2026-11-14T10:00:00.000Z");
  const out = await withTenant(fx.app, ctx, (tx) => writeAnchor(tx, ctx.tenantId, signer, now));
  const [row] = await anchors(ctx.tenantId);
  const head = (await fx.admin.query("select seq, hash from audit_events where tenant_id = $1 order by seq desc limit 1", [ctx.tenantId])).rows[0];
  expect(out).toMatchObject({ seq: 3, head_hash: head.hash, key_id: signer.keyId });
  expect(Number(row.seq)).toBe(3);
  expect(row.head_hash).toBe(head.hash);
  expect(row.key_id).toBe(signer.keyId);
  expect(row.sink_ref).toBeNull();
  expect((row.signed_at as Date).toISOString()).toBe(now.toISOString());
  const bytes = Buffer.from(jcs({ tenant_id: ctx.tenantId, seq: 3, head_hash: head.hash, signed_at: now.toISOString() }));
  const sig = Buffer.from(row.signature, "base64url");
  expect(edVerify(null, bytes, createPublicKey(signer.publicKeyPem), sig)).toBe(true);
  expect(signer.verify(bytes, new Uint8Array(sig), signer.keyId)).toBe(true);
  expect(signer.keyId).toMatch(/^[0-9a-f]{16}$/);
});

test("ANCHOR: no new anchor is written when the chain head has not moved", async () => {
  const signer = fakeSigner();
  const ctx = await newTenant(fx.app);
  const at = (h: number) => new Date(Date.UTC(2026, 10, 14, h));
  expect(await withTenant(fx.app, ctx, (tx) => writeAnchor(tx, ctx.tenantId, signer, at(10)))).not.toBeNull();
  expect(await withTenant(fx.app, ctx, (tx) => writeAnchor(tx, ctx.tenantId, signer, at(11)))).toBeNull();
  expect((await anchors(ctx.tenantId)).length).toBe(1);
  await appendN(fx.app, ctx, 1);
  expect(await withTenant(fx.app, ctx, (tx) => writeAnchor(tx, ctx.tenantId, signer, at(12)))).toMatchObject({ seq: 2 });
  expect((await anchors(ctx.tenantId)).length).toBe(2);
});

test("ANCHOR: offload_app cannot update or delete an anchor", async () => {
  const signer = fakeSigner();
  const ctx = await newTenant(fx.app);
  await withTenant(fx.app, ctx, (tx) => writeAnchor(tx, ctx.tenantId, signer, new Date()));
  const attempt = (sql: string) =>
    withTenant(fx.app, ctx, (tx) => tx.query(sql)).then(() => null, (e: Error) => e.message);
  expect(await attempt("update audit_anchors set key_id = 'x'")).toMatch(/append_only|permission denied/);
  expect(await attempt("delete from audit_anchors")).toMatch(/append_only|permission denied/);
  expect((await anchors(ctx.tenantId)).length).toBe(1);
});

test("ANCHOR: the signing key never appears in a row or a log line", async () => {
  const canary = fakeSigner();
  const dir = mkdtempSync(join(tmpdir(), "anchor-key-"));
  const ref = join(dir, "service-signing.pem");
  writeFileSync(ref, canary.pkcs8Pem, { mode: 0o600 });
  const body = canary.pkcs8Pem.split("\n").filter((l) => l && !l.startsWith("-----")).join("");
  const logs: string[] = [];
  const spies = (["log", "error", "warn", "info", "debug"] as const).map((m) =>
    spyOn(console, m).mockImplementation((...a: unknown[]) => void logs.push(a.map(String).join(" "))));
  try {
    const signer = fileSigner(ref);
    expect(signer.keyId).toBe(canary.keyId);
    const ctx = await newTenant(fx.app);
    await appendN(fx.app, ctx, 2);
    await withTenant(fx.app, ctx, (tx) => writeAnchor(tx, ctx.tenantId, signer, new Date("2026-11-14T10:00:00.000Z")));
    expect(await withTenant(fx.app, ctx, (tx) => verifyChain(tx, ctx.tenantId, signer))).toEqual({ ok: true, checked: 3 });
    const rows = JSON.stringify((await fx.admin.query("select a::text as r from audit_anchors a")).rows)
      + JSON.stringify((await fx.admin.query("select e::text as r from audit_events e")).rows);
    expect(rows).not.toContain(body);
    expect(rows).not.toContain("PRIVATE KEY");
  } finally {
    for (const s of spies) s.mockRestore();
  }
  expect(logs.join("\n")).not.toContain(body);
  expect(logs.join("\n")).not.toContain("PRIVATE KEY");
  // A missing key file fails closed without echoing a path's contents.
  expect(() => fileSigner(join(dir, "missing.pem"))).toThrow();
});
