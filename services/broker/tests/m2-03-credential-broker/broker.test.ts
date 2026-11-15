import { afterAll, beforeAll, expect, test } from "bun:test";
import { statSync } from "node:fs";
import { jcs, sha256Hex } from "@offload/contracts";
import { uuidv7 } from "@offload/db";
import { brokerClient } from "@offload/testkit/src/broker/index.ts";
import { COMPOSIO_KEY, SERVICE_TOKEN, auditActions, commitCall, connect, credentialRow, readCall, setup, type Env } from "./harness.ts";

let env: Env;
beforeAll(async () => {
  env = await setup({ keys: "kms" });
});
afterAll(async () => {
  await env.stop();
});

const itemHash = (args: unknown) => sha256Hex(jcs(args));
const RUN = "00000000-0000-7000-8000-0000000000aa";
const KEY = "sk_test_broker_key_000111222333";

async function withKey(): Promise<string> {
  const conn = await connect(env, env.fx.a);
  const r = await env.call("/credentials/api-key", { tenant_id: env.fx.a.tenantId, connection_id: conn, api_key: KEY });
  expect(r.status).toBe(200);
  return conn;
}

test("BROKER: a commit whose item hash is not in the approved batch is refused by the broker", async () => {
  const conn = await withKey();
  const approved = { amount: 100, to: "acct_1" };
  const other = { amount: 9999, to: "acct_evil" };
  const approvalId = uuidv7();
  env.approvals.approved.set(approvalId, new Set([itemHash(approved)]));
  // Control: the approved item goes through.
  const ok = await env.call("/call", commitCall(env, env.fx.a, conn, approved, { approval_id: approvalId }));
  expect(ok.status).toBe(200);
  expect(env.upstream.requests.length).toBe(1);
  const bad = await env.call("/call", commitCall(env, env.fx.a, conn, other, { approval_id: approvalId }));
  expect(bad.status).toBe(403);
  expect(bad.json.error.code).toBe("hash_mismatch");
  expect(env.upstream.requests.length).toBe(1); // upstream not called
  const refused = (await auditActions(env, env.fx.a)).filter((a) => a.action === "broker.refused");
  expect(refused.at(-1)?.details).toMatchObject({ code: "hash_mismatch", connection_id: conn, item_hash: itemHash(other) });
  // Unknown, used and expired approvals keep API.md's codes and statuses.
  const unknown = await env.call("/call", commitCall(env, env.fx.a, conn, approved));
  expect([unknown.status, unknown.json.error.code]).toEqual([403, "forbidden"]);
  const used = uuidv7();
  const expired = uuidv7();
  env.approvals.state.set(used, "approval_used");
  env.approvals.state.set(expired, "approval_expired");
  const u = await env.call("/call", commitCall(env, env.fx.a, conn, approved, { approval_id: used }));
  const e = await env.call("/call", commitCall(env, env.fx.a, conn, approved, { approval_id: expired }));
  expect([u.status, u.json.error.code]).toEqual([409, "approval_used"]);
  expect([e.status, e.json.error.code]).toEqual([409, "approval_expired"]);
  expect(env.upstream.requests.length).toBe(1);
});

test("BROKER: the broker hashes the arguments itself and ignores a caller-supplied item hash", async () => {
  const conn = await withKey();
  const approved = { amount: 5, to: "acct_ok" };
  const sent = { amount: 5000, to: "acct_other" };
  const approvalId = uuidv7();
  env.approvals.approved.set(approvalId, new Set([itemHash(approved)]));
  const before = env.upstream.requests.length;
  const r = await env.call("/call", commitCall(env, env.fx.a, conn, sent, { approval_id: approvalId, item_hash: itemHash(approved), item_hashes: [itemHash(approved)] }));
  expect([r.status, r.json.error.code]).toEqual([403, "hash_mismatch"]);
  expect(env.approvals.checks.at(-1)).toEqual({ approvalId, itemHash: itemHash(sent) });
  expect(env.upstream.requests.length).toBe(before);
});

test("BROKER: a read outside the run's declared read set is refused", async () => {
  const conn = await withKey();
  env.scope.runs.set(RUN, ["thing.read"]);
  const before = env.upstream.requests.length;
  const ok = await env.call("/call", readCall(env, env.fx.a, conn, "thing.read", { run_id: RUN }));
  expect(ok.status).toBe(200);
  const no = await env.call("/call", readCall(env, env.fx.a, conn, "thing.secret_list", { run_id: RUN }));
  expect([no.status, no.json.error.code]).toEqual([403, "read_not_declared"]);
  const unknownRun = await env.call("/call", readCall(env, env.fx.a, conn, "thing.read", { run_id: uuidv7() }));
  expect([unknownRun.status, unknownRun.json.error.code]).toEqual([403, "read_not_declared"]);
  const noRun = await env.call("/call", readCall(env, env.fx.a, conn, "thing.read"));
  expect([noRun.status, noRun.json.error.code]).toEqual([403, "read_not_declared"]);
  expect(env.upstream.requests.length).toBe(before + 1);
});

test("BROKER: gate mode read refuses every commit capability", async () => {
  const conn = await withKey();
  const args = { amount: 1 };
  const approvalId = uuidv7();
  env.approvals.approved.set(approvalId, new Set([itemHash(args)]));
  const checksBefore = env.approvals.checks.length;
  const before = env.upstream.requests.length;
  const r = await env.call("/call", commitCall(env, env.fx.a, conn, args, { approval_id: approvalId, gate_mode: "read" }));
  expect([r.status, r.json.error.code]).toEqual([403, "gate_read_only"]);
  expect(env.approvals.checks.length).toBe(checksBefore);
  expect(env.upstream.requests.length).toBe(before);
  // Fixture capture: a read in gate mode read with a fixture set is allowed when the set names the capability.
  const fixtureSet = uuidv7();
  env.scope.fixtureSets.set(fixtureSet, ["thing.read"]);
  const fx = await env.call("/call", readCall(env, env.fx.a, conn, "thing.read", { gate_mode: "read", fixture_set_id: fixtureSet }));
  expect(fx.status).toBe(200);
  const outside = await env.call("/call", readCall(env, env.fx.a, conn, "thing.other", { gate_mode: "read", fixture_set_id: fixtureSet }));
  expect(outside.json.error.code).toBe("read_not_declared");
});

test("BROKER: a request without the service token or with a wrong one is 401 before any lookup", async () => {
  const conn = await withKey();
  let used = 0;
  const realConnect = env.pool.connect.bind(env.pool);
  const realQuery = env.pool.query.bind(env.pool);
  (env.pool as any).connect = (...a: unknown[]) => (used++, (realConnect as any)(...a));
  (env.pool as any).query = (...a: unknown[]) => (used++, (realQuery as any)(...a));
  const lookups = env.scope.lookups.length;
  const checks = env.approvals.checks.length;
  try {
    const body = readCall(env, env.fx.a, conn, "thing.read", { run_id: RUN });
    for (const token of [null, "wrong-token", SERVICE_TOKEN.slice(0, -1), `${SERVICE_TOKEN}x`]) {
      const r = await brokerClient(env.socket, token)("/call", body);
      expect(r.status).toBe(401);
      expect(r.json.error.code).toBe("unauthenticated");
    }
    const raw = await brokerClient(env.socket, null)("/call", body, { authorization: `Basic ${SERVICE_TOKEN}` });
    expect(raw.status).toBe(401);
    expect(used).toBe(0);
    expect(env.scope.lookups.length).toBe(lookups);
    expect(env.approvals.checks.length).toBe(checks);
    // Control: the right token does reach the database.
    env.scope.runs.set(RUN, ["thing.read"]);
    expect((await env.call("/call", body)).status).toBe(200);
    expect(used).toBeGreaterThan(0);
  } finally {
    (env.pool as any).connect = realConnect;
    (env.pool as any).query = realQuery;
  }
});

test("BROKER: a request to a host outside the provider allowlist is refused and nothing is decrypted", async () => {
  const conn = await withKey();
  env.scope.runs.set(RUN, ["thing.read"]);
  const decryptsBefore = env.kms.decrypts.length;
  const before = env.upstream.requests.length;
  for (const url of ["https://evil.example.test/steal", "http://127.0.0.1:9/x", `http://${env.upstream.host}.evil.test/x`, "ftp://x.test/y"]) {
    const r = await env.call("/call", { ...readCall(env, env.fx.a, conn, "thing.read", { run_id: RUN }), request: { method: "GET", url, headers: {} } });
    expect(r.status).toBe(403);
    expect(["host_not_allowed", "invalid_request"]).toContain(r.json.error.code);
  }
  const first = await env.call("/call", { ...readCall(env, env.fx.a, conn, "thing.read", { run_id: RUN }), request: { method: "GET", url: "https://evil.example.test/steal", headers: {} } });
  expect(first.json.error.code).toBe("host_not_allowed");
  expect(env.kms.decrypts.length).toBe(decryptsBefore);
  expect(env.upstream.requests.length).toBe(before);
});

test("BROKER: the credential reaches only the upstream auth header and never the caller", async () => {
  const conn = await withKey();
  env.scope.runs.set(RUN, ["thing.read"]);
  env.upstream.respond = () => new Response(JSON.stringify({ fine: true }), { headers: { "content-type": "application/json", "set-cookie": "s=1", "x-secret-echo": KEY } });
  const r = await env.call("/call", {
    ...readCall(env, env.fx.a, conn, "thing.read", { run_id: RUN }),
    request: { method: "GET", url: `http://${env.upstream.host}/v1/things`, headers: { Authorization: "Bearer attacker-supplied", "X-Api-Key": "attacker", cookie: "a=b", "x-trace": "t1" } },
  });
  expect(r.status).toBe(200);
  const seen = env.upstream.requests.at(-1)!;
  expect(seen.headers["authorization"]).toBe(`Bearer ${KEY}`);
  expect(seen.headers["x-api-key"]).toBeUndefined();
  expect(seen.headers["cookie"]).toBeUndefined();
  expect(seen.headers["x-trace"]).toBe("t1");
  expect(r.text.includes(KEY)).toBe(false);
  expect(r.json).toEqual({ status: 200, headers: { "content-type": "application/json" }, body: JSON.stringify({ fine: true }) });
});

test("BROKER: the socket file is mode 0600", () => {
  expect(statSync(env.socket).mode & 0o777).toBe(0o600);
});

test("BROKER: the composio adapter sends x-api-key and the member uuid as user_id, with no vault row", async () => {
  const t = env.fx.a;
  const conn = await connect(env, t, { adapter: "composio", provider: "slack", member: t.member });
  env.scope.runs.set(RUN, ["message.read"]);
  env.upstream.respond = () => Response.json({ items: [] });
  const r = await env.call("/call", {
    ...readCall(env, t, conn, "message.read", { run_id: RUN }),
    request: { method: "POST", url: `http://${env.upstream.host}/api/v3/tools/execute/SLACK_LIST`, headers: { "content-type": "application/json" }, body: JSON.stringify({ arguments: {} }) },
  });
  expect(r.status).toBe(200);
  const seen = env.upstream.requests.at(-1)!;
  expect(seen.headers["x-api-key"]).toBe(COMPOSIO_KEY);
  expect(seen.headers["authorization"]).toBeUndefined();
  expect(JSON.parse(seen.body).user_id).toBe(t.member);
  expect(r.text.includes(COMPOSIO_KEY)).toBe(false);
  expect(await credentialRow(env, t, conn)).toBeUndefined();
});

test("BROKER: tools/list uses the same outbound rules and returns the raw tool list", async () => {
  const t = env.fx.a;
  const conn = await connect(env, t, { adapter: "mcp", provider: "notion" });
  await env.call("/credentials/api-key", { tenant_id: t.tenantId, connection_id: conn, api_key: KEY });
  env.upstream.respond = () => Response.json({ jsonrpc: "2.0", id: 1, result: { tools: [{ name: "search", description: "find pages" }] } });
  const r = await env.call("/tools/list", { tenant_id: t.tenantId, connection_id: conn });
  expect(r.status).toBe(200);
  expect(r.json.tools).toEqual([{ name: "search", description: "find pages" }]);
  const seen = env.upstream.requests.at(-1)!;
  expect(seen.headers["authorization"]).toBe(`Bearer ${KEY}`);
  expect(JSON.parse(seen.body).method).toBe("tools/list");
});
