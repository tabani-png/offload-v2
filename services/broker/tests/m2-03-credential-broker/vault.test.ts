import { afterAll, beforeAll, expect, test } from "bun:test";
import { withTenant, uuidv7 } from "@offload/db";
import { sha256Hex } from "@offload/contracts";
import { auditActions, connect, connectionState, credentialRow, readCall, setup, type Env } from "./harness.ts";

let env: Env;
beforeAll(async () => {
  env = await setup();
});
afterAll(async () => {
  await env.stop();
});

const CANARY = "CANARY-vault-secret-7f3a91c2d4e5b6a7";

test("VAULT: credential plaintext never appears in logs, events or model prompts", async () => {
  const t = env.fx.a;
  const conn = await connect(env, t);
  const put = await env.call("/credentials/api-key", { tenant_id: t.tenantId, connection_id: conn, api_key: CANARY });
  expect(put.status).toBe(200);
  env.scope.runs.set("00000000-0000-7000-8000-000000000001", ["thing.read"]);
  // An upstream that echoes the auth header back into its body.
  env.upstream.respond = (req) => Response.json({ echo: req.headers["authorization"], again: `token=${req.headers["authorization"]}` });
  const ok = await env.call("/call", readCall(env, t, conn, "thing.read", { run_id: "00000000-0000-7000-8000-000000000001" }));
  expect(ok.status).toBe(200);
  expect(env.upstream.requests.at(-1)?.headers["authorization"]).toBe(`Bearer ${CANARY}`);
  // Refusals and errors on the same connection.
  await env.call("/call", readCall(env, t, conn, "thing.undeclared", { run_id: "00000000-0000-7000-8000-000000000001" }));
  await env.call("/call", { ...readCall(env, t, conn, "thing.read"), request: { method: "GET", url: "http://evil.example.test/x", headers: { authorization: CANARY } } });
  await env.call("/call", { tenant_id: t.tenantId, junk: CANARY });
  const variants = [CANARY, Buffer.from(CANARY).toString("base64"), encodeURIComponent(CANARY), Buffer.from(CANARY).toString("hex")];
  const haystacks: Record<string, string> = {
    logs: env.logs.join("\n"),
    replies: env.replies.join("\n"),
    audit: JSON.stringify((await env.fx.admin.query("select * from audit_events")).rows),
    outbox: JSON.stringify((await env.fx.admin.query("select * from events_outbox")).rows),
  };
  expect(env.logs.length).toBeGreaterThan(0); // not vacuous
  for (const [name, text] of Object.entries(haystacks)) for (const v of variants) expect(`${name}:${text.includes(v)}`).toBe(`${name}:false`);
  const row = await credentialRow(env, t, conn);
  expect((row.ciphertext as Buffer).includes(Buffer.from(CANARY))).toBe(false);
  expect((await auditActions(env, t)).map((a) => a.action)).toContain("credential.stored");
});

test("VAULT: offload_app cannot select, insert or update credentials or oauth_requests", async () => {
  const t = env.fx.a;
  const conn = await connect(env, t);
  await env.broker.vault.put(t.tenantId, conn, { kind: "api_key", api_key: "k-denied-check" }, { scopes: [], expiresAt: null });
  const ctx = env.fx.ctx(t, t.owner);
  const statements: [string, unknown[]][] = [
    ["select * from credentials", []],
    ["select count(*) from oauth_requests", []],
    ["insert into credentials (tenant_id, connection_id, ciphertext, nonce, wrapped_dek, key_provider, key_ref) values ($1, $2, '\\x00', '\\x00', '\\x00', 'local', 'x')", [t.tenantId, conn]],
    ["insert into oauth_requests (tenant_id, state_sha256, connection_id, member_id, provider, code_verifier, redirect_uri, expires_at) values ($1, $2, $3, $4, 'stripe', 'v', 'https://x.test/cb', now())", [t.tenantId, sha256Hex("s"), conn, t.owner]],
    ["update credentials set refresh_state = 'ok'", []],
    ["update oauth_requests set used_at = now()", []],
    ["delete from credentials", []],
  ];
  for (const [sql, params] of statements) {
    const err = await withTenant(env.fx.app, ctx, (tx) => tx.query(sql, params)).then(() => null, (e: Error) => e);
    expect(`${sql.slice(0, 40)} -> ${err?.message ?? "allowed"}`).toMatch(/permission denied/);
  }
});

test("VAULT: a ciphertext does not decrypt under another connection's AAD", async () => {
  const t = env.fx.a;
  const c1 = await connect(env, t);
  const c2 = await connect(env, t);
  await env.broker.vault.put(t.tenantId, c1, { kind: "api_key", api_key: "secret-for-c1" }, { scopes: [], expiresAt: null });
  await env.broker.vault.put(t.tenantId, c2, { kind: "api_key", api_key: "secret-for-c2" }, { scopes: [], expiresAt: null });
  expect((await env.broker.vault.get(t.tenantId, c1)).secret).toEqual({ kind: "api_key", api_key: "secret-for-c1" });
  // Move c1's ciphertext and wrapped key onto c2's row: same tenant, same key, different connection id in the AAD.
  const r1 = await credentialRow(env, t, c1);
  await env.fx.admin.query(
    "update credentials set ciphertext = $3, nonce = $4, wrapped_dek = $5 where tenant_id = $1 and connection_id = $2",
    [t.tenantId, c2, r1.ciphertext, r1.nonce, r1.wrapped_dek],
  );
  await expect(env.broker.vault.get(t.tenantId, c2)).rejects.toMatchObject({ code: "server_error" });
});

test("VAULT: shred deletes the credential and a later call on that connection fails", async () => {
  const t = env.fx.a;
  const conn = await connect(env, t);
  await env.call("/credentials/api-key", { tenant_id: t.tenantId, connection_id: conn, api_key: "k-to-shred" });
  expect(await credentialRow(env, t, conn)).toBeDefined();
  const s = await env.call("/credentials/shred", { tenant_id: t.tenantId, connection_id: conn });
  expect(s.status).toBe(204);
  expect(await credentialRow(env, t, conn)).toBeUndefined();
  expect(await connectionState(env, t, conn)).toBe("revoked");
  const before = env.upstream.requests.length;
  env.scope.runs.set("00000000-0000-7000-8000-000000000002", ["thing.read"]);
  const after = await env.call("/call", readCall(env, t, conn, "thing.read", { run_id: "00000000-0000-7000-8000-000000000002" }));
  expect(after.status).toBeGreaterThanOrEqual(400);
  expect(env.upstream.requests.length).toBe(before);
  const shredded = (await auditActions(env, t)).filter((a) => a.action === "credential.shredded");
  expect(shredded.length).toBe(1);
  expect(shredded[0]!.details).toEqual({ connection_id: conn });
  // Shredding again is idempotent.
  expect((await env.call("/credentials/shred", { tenant_id: t.tenantId, connection_id: conn })).status).toBe(204);
  // Tenant shred removes every row of that tenant and none of the other's.
  const c3 = await connect(env, t);
  const other = await connect(env, env.fx.b);
  await env.broker.vault.put(t.tenantId, c3, { kind: "api_key", api_key: "k3" }, { scopes: [], expiresAt: null });
  await env.broker.vault.put(env.fx.b.tenantId, other, { kind: "api_key", api_key: "kb" }, { scopes: [], expiresAt: null });
  await env.broker.vault.shredTenant(t.tenantId);
  expect(await credentialRow(env, t, c3)).toBeUndefined();
  expect(await credentialRow(env, env.fx.b, other)).toBeDefined();
  void uuidv7;
});
