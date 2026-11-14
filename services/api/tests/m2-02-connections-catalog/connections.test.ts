import { afterAll, beforeAll, expect, test } from "bun:test";
import { randomBytes } from "node:crypto";
import { sha256Hex } from "@offload/contracts";
import { ConnectionCreatedSchema, ConnectionSchema, ToolPinListSchema } from "@offload/contracts/src/connections/index.ts";
import { toolPinHash } from "@offload/connectors-sdk";
import { ulid, withTenant } from "@offload/db";
import { FakeBroker } from "@offload/testkit/src/connectors/index.ts";
import {
  BASE, CALLBACK_URI, auditActions, callsOf, connectOAuth, connectionRow, createConnection, ids, makeHarness, pinRows,
  session, user, type ConnHarness,
} from "./harness.ts";

let h: ConnHarness;
beforeAll(async () => {
  h = await makeHarness();
});
afterAll(async () => {
  await h.close();
});

const GMAIL_TOOLS = [
  {
    name: "gmail_send_message",
    description: "Sends an email message.",
    input_schema: { type: "object", properties: { to: { type: "string" }, subject: { type: "string" } }, required: ["to"] },
    annotations: { readOnlyHint: false },
  },
  {
    name: "gmail_search",
    description: "Searches messages.",
    input_schema: { type: "object", properties: { q: { type: "string" } } },
    annotations: { readOnlyHint: true },
  },
];

const expectedPins = (tools: typeof GMAIL_TOOLS) =>
  tools
    .map((t) => ({ name: t.name, pin_hash: toolPinHash({ name: t.name, description: t.description, input_schema: t.input_schema }) }))
    .sort((a, b) => (a.name < b.name ? -1 : a.name > b.name ? 1 : 0));

test("CONNECTION: POST for a google_internal app returns the broker's authorize_url and stores the connection as needs_reauth", async () => {
  const s = await session(h, user("gi-post"));
  const { tenantId, workspaceId, memberId } = ids(s);
  const entry = h.catalog.find((e) => e.provider === "gmail")!;
  expect(entry.method).toBe("google_internal");
  const before = h.broker.calls.length;

  const r = await createConnection(h, s, { provider: "gmail", adapter: "openapi" });
  expect(r.res.status).toBe(201);
  const body = ConnectionCreatedSchema.parse(r.body);
  expect(body.authorize_url).toBeDefined();
  expect(body.authorize_url!.startsWith("https://auth.broker.test/authorize?state=")).toBe(true);

  const begins = h.broker.calls.slice(before).filter((c) => c.method === "oauthBegin");
  expect(begins.length).toBe(1);
  const input = begins[0]!.input as any;
  expect(input.tenant_id).toBe(tenantId);
  expect(input.connection_id).toBe(body.connection_id);
  expect(input.provider).toBe("gmail");
  expect(input.scopes).toEqual(entry.scopes);
  expect(input.redirect_uri).toBe(CALLBACK_URI);
  expect(input.redirect_uri.endsWith("/v1/connections/callback")).toBe(true);
  expect(input.composio).toBeUndefined();

  const row = await connectionRow(h, body.connection_id);
  expect(row).toBeDefined();
  expect(row.tenant_id).toBe(tenantId);
  expect(row.workspace_id).toBe(workspaceId);
  expect(row.member_id).toBe(memberId);
  expect(row.adapter).toBe("openapi");
  expect(row.provider).toBe("gmail");
  expect(row.state).toBe("needs_reauth");
  expect(row.account_label).toBeNull();
  expect(row.account_hash).toBeNull();
  expect(row.capabilities).toEqual(entry.capabilities);
  // No token-like value: nothing from the authorize URL (state) lands in the row.
  const state = new URL(body.authorize_url!).searchParams.get("state")!;
  expect(JSON.stringify(row)).not.toContain(state);
  for (const k of Object.keys(row)) expect(k).not.toMatch(/token|secret|api_key|password/i);

  expect(await auditActions(h, tenantId, body.connection_id)).toEqual(["connection.created"]);
});

test("CONNECTION: the callback activates the connection with the account label and pins its tools", async () => {
  const s = await session(h, user("gi-callback"));
  const { tenantId } = ids(s);
  h.broker.setTools("google_sheets", GMAIL_TOOLS);
  const f = await connectOAuth(h, s, "google_sheets", "openapi");

  expect(f.callback.status).toBe(302);
  expect(f.callback.headers.get("location")).toBe(`${BASE}/connections?connection_id=${f.connectionId}`);

  const finishes = callsOf(h.broker, "oauthFinish").filter((c) => (c.input as any).state === f.state);
  expect(finishes.length).toBe(1);
  expect((finishes[0]!.input as any).tenant_id).toBe(tenantId);

  const row = await connectionRow(h, f.connectionId);
  expect(row.state).toBe("active");
  expect(typeof row.account_label).toBe("string");
  expect(row.account_label.length).toBeGreaterThan(0);
  expect(row.account_hash).toMatch(/^[0-9a-f]{64}$/);

  const pins = await pinRows(h, tenantId, f.connectionId);
  expect(pins.map((p) => ({ name: p.tool_name, pin_hash: p.pin_hash }))).toEqual(expectedPins(GMAIL_TOOLS));

  expect(await auditActions(h, tenantId, f.connectionId)).toEqual(["connection.created", "connection.activated", "connection.pins_recorded"]);
});

test("CONNECTION: an openapi api_key goes to the broker only and never into a row, a log line, an audit event or the response", async () => {
  const s = await session(h, user("stripe-key"));
  const { tenantId } = ids(s);
  const canary = `rk_test_canary_${randomBytes(12).toString("hex")}`;
  const canaryHash = sha256Hex(canary);

  const methods = ["log", "info", "warn", "error", "debug", "trace"] as const;
  const lines: string[] = [];
  const saved = methods.map((m) => [m, console[m]] as const);
  const savedOut = process.stdout.write.bind(process.stdout);
  const savedErr = process.stderr.write.bind(process.stderr);
  const show = (a: unknown) => {
    if (typeof a === "string") return a;
    try {
      return JSON.stringify(a) ?? String(a);
    } catch {
      return String(a);
    }
  };
  let r: Awaited<ReturnType<typeof createConnection>>;
  try {
    for (const m of methods) (console as any)[m] = (...args: unknown[]) => lines.push(args.map(show).join(" "));
    (process.stdout as any).write = (chunk: unknown, ...rest: unknown[]) => (lines.push(String(chunk)), true);
    (process.stderr as any).write = (chunk: unknown, ...rest: unknown[]) => (lines.push(String(chunk)), true);
    r = await createConnection(h, s, { provider: "stripe", adapter: "openapi", api_key: canary }, { headers: { "idempotency-key": ulid() } });
  } finally {
    for (const [m, fn] of saved) (console as any)[m] = fn;
    (process.stdout as any).write = savedOut;
    (process.stderr as any).write = savedErr;
  }

  expect(r.res.status).toBe(201);
  const body = ConnectionCreatedSchema.parse(r.body);
  expect(body.authorize_url).toBeUndefined();
  expect(r.text).not.toContain("canary");
  expect(r.text).not.toContain(canaryHash);
  for (const [, v] of r.res.headers) expect(v).not.toContain("canary");

  for (const line of lines) {
    expect(line).not.toContain("canary");
    expect(line).not.toContain(canaryHash);
  }

  const puts = callsOf(h.broker, "putApiKey").filter((c) => (c.input as any).connection_id === body.connection_id);
  expect(puts.length).toBe(1);
  expect((puts[0]!.input as any).api_key).toBe(canary);
  expect((puts[0]!.input as any).tenant_id).toBe(tenantId);

  const tables = (await h.fx.admin.query(
    "select table_name from information_schema.tables where table_schema = 'public' and table_type = 'BASE TABLE' order by 1",
  )).rows.map((x) => x.table_name as string);
  expect(tables).toContain("connections");
  expect(tables).toContain("connection_tool_pins");
  expect(tables).toContain("idempotency_keys");
  expect(tables).toContain("audit_events");
  const hits: Record<string, number> = {};
  for (const t of tables) {
    const q = `select count(*)::int as n from public."${t.replace(/"/g, '""')}" as r where r::text like '%canary%' or r::text like $1`;
    hits[t] = (await h.fx.admin.query(q, [`%${canaryHash}%`])).rows[0].n;
  }
  expect(hits).toEqual(Object.fromEntries(tables.map((t) => [t, 0])));
  // The request was recorded under its Idempotency-Key, without the key.
  expect((await h.fx.admin.query("select count(*)::int as n from idempotency_keys where tenant_id = $1", [tenantId])).rows[0].n).toBeGreaterThanOrEqual(1);

  const row = await connectionRow(h, body.connection_id);
  expect(row.state).toBe("active");
  expect(row.provider).toBe("stripe");
  expect(row.adapter).toBe("openapi");
  expect((await pinRows(h, tenantId, body.connection_id)).length).toBeGreaterThan(0);
  expect(await auditActions(h, tenantId, body.connection_id)).toEqual(["connection.created", "connection.activated", "connection.pins_recorded"]);
});

test("CONNECTION: DELETE asks the broker to shred and marks the connection revoked", async () => {
  const s = await session(h, user("delete"));
  const { tenantId } = ids(s);
  const c = await createConnection(h, s, { provider: "stripe", adapter: "openapi", api_key: "rk_test_delete_key" });
  expect(c.res.status).toBe(201);
  const id = c.body.connection_id as string;
  const shredsFor = () => callsOf(h.broker, "shred").filter((x) => (x.input as any).connection_id === id);

  const del = await h.req(`/v1/connections/${id}`, { method: "DELETE", cookie: s.cookie, csrf: s.csrf });
  expect(del.status).toBe(204);
  expect(shredsFor().length).toBe(1);
  expect(shredsFor()[0]!.input).toEqual({ tenant_id: tenantId, connection_id: id });
  expect((await connectionRow(h, id)).state).toBe("revoked");
  expect((await auditActions(h, tenantId, id)).filter((a) => a === "connection.revoked")).toEqual(["connection.revoked"]);

  const again = await h.req(`/v1/connections/${id}`, { method: "DELETE", cookie: s.cookie, csrf: s.csrf });
  expect(again.status).toBe(204);
  expect(shredsFor().length).toBe(1);
  expect((await auditActions(h, tenantId, id)).filter((a) => a === "connection.revoked").length).toBe(1);
  expect((await connectionRow(h, id)).state).toBe("revoked");
});

test("CONNECTION: GET /v1/connections never returns external_ref, account_hash or any secret field", async () => {
  const s = await session(h, user("list"));
  const { tenantId } = ids(s);
  const a = await createConnection(h, s, { provider: "stripe", adapter: "openapi", api_key: "rk_test_list_key" });
  expect(a.res.status).toBe(201);
  const g = await createConnection(h, s, { provider: "gmail", adapter: "openapi" });
  expect(g.res.status).toBe(201);
  const externalRef = `ext_ref_${randomBytes(8).toString("hex")}`;
  const accountHash = sha256Hex(`account-${externalRef}`);
  await h.fx.admin.query("update connections set external_ref = $1, account_hash = $2 where tenant_id = $3", [externalRef, accountHash, tenantId]);

  const res = await h.req("/v1/connections", { cookie: s.cookie });
  expect(res.status).toBe(200);
  const text = await res.text();
  expect(text).not.toContain(externalRef);
  expect(text).not.toContain(accountHash);
  expect(text).not.toContain("rk_test_list_key");
  const items = JSON.parse(text) as Record<string, unknown>[];
  expect(Array.isArray(items)).toBe(true);
  const listed = items.map((i) => i["connection_id"]);
  expect(listed).toContain(a.body.connection_id);
  expect(listed).toContain(g.body.connection_id);
  const schemaKeys = Object.keys(ConnectionSchema.shape).sort();
  for (const item of items) {
    ConnectionSchema.parse(item);
    expect(Object.keys(item).sort()).toEqual(schemaKeys);
    for (const k of ["external_ref", "account_hash", "api_key", "token", "secret", "credential"]) expect(item).not.toHaveProperty(k);
  }
  const stripe = items.find((i) => i["connection_id"] === a.body.connection_id)!;
  expect(stripe["state"]).toBe("active");
  expect(stripe["provider"]).toBe("stripe");
  const gmail = items.find((i) => i["connection_id"] === g.body.connection_id)!;
  expect(gmail["state"]).toBe("needs_reauth");
  expect(gmail["account_label"]).toBeNull();
});

test("CONNECTION: connections of tenant A are invisible to tenant B", async () => {
  const sa = await session(h, user("tenant-a"));
  const sb = await session(h, user("tenant-b"));
  expect(ids(sa).tenantId).not.toBe(ids(sb).tenantId);
  const c = await createConnection(h, sa, { provider: "stripe", adapter: "openapi", api_key: "rk_test_tenant_a" });
  expect(c.res.status).toBe(201);
  const id = c.body.connection_id as string;
  const rowBefore = await connectionRow(h, id);
  const shredsBefore = callsOf(h.broker, "shred").length;

  const list = await h.req("/v1/connections", { cookie: sb.cookie });
  expect(list.status).toBe(200);
  expect(((await list.json()) as any[]).map((i) => i.connection_id)).not.toContain(id);

  const tools = await h.req(`/v1/connections/${id}/tools`, { cookie: sb.cookie });
  expect(tools.status).toBe(404);
  const del = await h.req(`/v1/connections/${id}`, { method: "DELETE", cookie: sb.cookie, csrf: sb.csrf });
  expect(del.status).toBe(404);

  expect(callsOf(h.broker, "shred").length).toBe(shredsBefore);
  expect(await connectionRow(h, id)).toEqual(rowBefore);
  // A still sees it.
  const own = await h.req(`/v1/connections/${id}/tools`, { cookie: sa.cookie });
  expect(own.status).toBe(200);
});

test("CONNECTION: no broker call happens inside withTenant", async () => {
  const s = await session(h, user("no-tx"));
  const before = h.broker.calls.length;
  const f = await connectOAuth(h, s, "google_calendar", "openapi");
  expect(f.callback.status).toBe(302);
  const k = await createConnection(h, s, { provider: "stripe", adapter: "openapi", api_key: "rk_test_no_tx" });
  expect(k.res.status).toBe(201);
  for (const id of [f.connectionId, k.body.connection_id as string]) {
    expect((await h.req(`/v1/connections/${id}`, { method: "DELETE", cookie: s.cookie, csrf: s.csrf })).status).toBe(204);
  }
  const calls = h.broker.calls.slice(before);
  expect(new Set(calls.map((c) => c.method))).toEqual(new Set(["oauthBegin", "oauthFinish", "putApiKey", "listTools", "shred"]));
  expect(calls.filter((c) => c.insideTransaction)).toEqual([]);

  // The guard itself: a FakeBroker called inside withTenant records the call and rejects.
  const fake = new FakeBroker();
  const ctx = h.fx.ctx(h.fx.a, h.fx.a.owner);
  await expect(
    withTenant(h.fx.app, ctx, () => fake.listTools({ tenant_id: h.fx.a.tenantId, connection_id: "00000000-0000-7000-8000-000000000000" })),
  ).rejects.toThrow();
  expect(fake.calls.length).toBe(1);
  expect(fake.calls[0]!.insideTransaction).toBe(true);
});

test("CONNECTION: GET /v1/connections without a session or member token is 401", async () => {
  const res = await h.req("/v1/connections");
  expect(res.status).toBe(401);
  expect(((await res.json()) as any).error.code).toBe("unauthenticated");
  const post = await h.req("/v1/connections", { method: "POST", json: { provider: "stripe", adapter: "openapi", workspace_id: h.fx.a.workspaceId, personal: true, api_key: "rk_x" } });
  expect(post.status).toBe(401);
});

test("CONNECTION: a session POST without X-CSRF-Token is 403", async () => {
  const s = await session(h, user("csrf"));
  const before = h.broker.calls.length;
  const res = await h.req("/v1/connections", {
    method: "POST", cookie: s.cookie,
    json: { provider: "stripe", adapter: "openapi", workspace_id: ids(s).workspaceId, personal: true, api_key: "rk_test_csrf" },
  });
  expect(res.status).toBe(403);
  expect(((await res.json()) as any).error.code).toBe("forbidden");
  expect(h.broker.calls.length).toBe(before);
  expect((await h.fx.admin.query("select count(*)::int as n from connections where tenant_id = $1", [ids(s).tenantId])).rows[0].n).toBe(0);
});

test("PIN: GET /v1/connections/{id}/tools returns the stored pins", async () => {
  const s = await session(h, user("pins-get"));
  const { tenantId } = ids(s);
  h.broker.setTools("google_drive", GMAIL_TOOLS);
  const f = await connectOAuth(h, s, "google_drive", "openapi");
  expect(f.callback.status).toBe(302);

  const res = await h.req(`/v1/connections/${f.connectionId}/tools`, { cookie: s.cookie });
  expect(res.status).toBe(200);
  const body = ToolPinListSchema.parse(await res.json());
  expect(body.tools).toEqual(expectedPins(GMAIL_TOOLS));
  const names = body.tools.map((t) => t.name);
  expect(names).toEqual([...names].sort());
  const stored = await pinRows(h, tenantId, f.connectionId);
  expect(body.tools).toEqual(stored.map((p) => ({ name: p.tool_name, pin_hash: p.pin_hash })));

  expect((await h.req("/v1/connections/not-a-uuid/tools", { cookie: s.cookie })).status).toBe(404);
});
