import { afterAll, beforeAll, expect, test } from "bun:test";
import { sha256Hex } from "@offload/contracts";
import { ulid, uuidv7 } from "@offload/db";
import {
  auditActions, callsOf, connectOAuth, connectionRow, createConnection, ids, makeHarness, pinRows, session, user,
  type ConnHarness, type Session,
} from "./harness.ts";

/** Red tests from the m2-02 review: atomic activation, roles, races, idempotency bound to the member, coverage gaps. */

let h: ConnHarness;
beforeAll(async () => {
  h = await makeHarness();
});
afterAll(async () => {
  await h.close();
});

/** Adds a member with `role` to the tenant of `owner` (and to its workspace unless `inWorkspace` is false), then logs in
 * as them through the fake OIDC issuer. */
async function joinTenant(owner: Session, label: string, role: "admin" | "member" | "auditor", inWorkspace = true): Promise<Session> {
  const u = user(label);
  const { tenantId, workspaceId } = ids(owner);
  const memberId = uuidv7();
  await h.fx.admin.query(
    "insert into members (tenant_id, id, email, email_hash, tenant_role, state, idp_subject) values ($1, $2, $3, $4, $5, 'active', $6)",
    [tenantId, memberId, u.email, sha256Hex(u.email), role, `oidc|${h.issuer.issuer}|${u.subject}`],
  );
  if (inWorkspace) {
    await h.fx.admin.query(
      "insert into workspace_members (tenant_id, workspace_id, member_id, workspace_role) values ($1, $2, $3, 'member')",
      [tenantId, workspaceId, memberId],
    );
  }
  const s = await session(h, u);
  expect(s.me.member.id).toBe(memberId);
  expect(s.me.tenant.id).toBe(tenantId);
  return s;
}

const stripe = (key: string) => ({ provider: "stripe", adapter: "openapi", api_key: key });
const countRows = async (sql: string, params: unknown[]) => (await h.fx.admin.query(sql, params)).rows[0].n as number;

// ---- 1. activation and pins are atomic ------------------------------------------------------------------------

test("CONNECTION: a tool listing failure at the callback leaves the connection needs_reauth with no pins", async () => {
  const s = await session(h, user("cb-list-fails"));
  const { tenantId } = ids(s);
  const created = await createConnection(h, s, { provider: "google_sheets", adapter: "openapi" });
  expect(created.res.status).toBe(201);
  const id = created.body.connection_id as string;
  const state = new URL(created.body.authorize_url).searchParams.get("state")!;

  h.broker.failNext("listTools");
  const cb = await h.req(`/v1/connections/callback?${new URLSearchParams({ state, code: "code-1" })}`, { cookie: s.cookie });
  expect(cb.status).not.toBe(302);
  expect(cb.status).toBeGreaterThanOrEqual(400);

  const row = await connectionRow(h, id);
  expect(row.state).toBe("needs_reauth");
  expect(row.account_label).toBeNull();
  expect(row.account_hash).toBeNull();
  expect(await pinRows(h, tenantId, id)).toEqual([]);
  const actions = await auditActions(h, tenantId, id);
  expect(actions).not.toContain("connection.activated");
  expect(actions).not.toContain("connection.pins_recorded");
});

test("CONNECTION: a tool listing failure after an api key is stored shreds the key and revokes the connection", async () => {
  const s = await session(h, user("key-list-fails"));
  const { tenantId } = ids(s);
  const key = ulid();
  const body = stripe("rk_test_list_fails");

  h.broker.failNext("listTools");
  const first = await createConnection(h, s, body, { headers: { "idempotency-key": key } });
  expect(first.res.status).toBeGreaterThanOrEqual(400);
  const rows = (await h.fx.admin.query("select id, state from connections where tenant_id = $1", [tenantId])).rows;
  expect(rows.length).toBe(1);
  const failedId = rows[0].id as string;
  expect(rows[0].state).toBe("revoked");
  expect(callsOf(h.broker, "shred").filter((c) => (c.input as any).connection_id === failedId).length).toBe(1);
  expect(await pinRows(h, tenantId, failedId)).toEqual([]);
  expect(await auditActions(h, tenantId, failedId)).not.toContain("connection.activated");

  // The same Idempotency-Key may be retried and makes a new connection that ends active.
  const retry = await createConnection(h, s, body, { headers: { "idempotency-key": key } });
  expect(retry.res.status).toBe(201);
  const newId = retry.body.connection_id as string;
  expect(newId).not.toBe(failedId);
  expect((await connectionRow(h, newId)).state).toBe("active");
  expect((await pinRows(h, tenantId, newId)).length).toBeGreaterThan(0);
  expect((await connectionRow(h, failedId)).state).toBe("revoked");
});

// ---- 2. auditors cannot change connections ----------------------------------------------------------------------

test("CONNECTION: an auditor gets 403 forbidden on POST, DELETE and the callback", async () => {
  const owner = await session(h, user("aud-owner"));
  const auditor = await joinTenant(owner, "aud-auditor", "auditor");
  const before = callsOf(h.broker, "putApiKey").length + callsOf(h.broker, "oauthBegin").length;

  const post = await createConnection(h, auditor, stripe("rk_test_auditor"));
  expect(post.res.status).toBe(403);
  expect(post.body.error.code).toBe("forbidden");
  expect(callsOf(h.broker, "putApiKey").length + callsOf(h.broker, "oauthBegin").length).toBe(before);

  // A workspace connection (visible to the auditor) cannot be deleted by them.
  const ws = await createConnection(h, owner, { ...stripe("rk_test_aud_ws"), personal: false });
  expect(ws.res.status).toBe(201);
  const shreds = callsOf(h.broker, "shred").length;
  const del = await h.req(`/v1/connections/${ws.body.connection_id}`, { method: "DELETE", cookie: auditor.cookie, csrf: auditor.csrf });
  expect(del.status).toBe(403);
  expect(((await del.json()) as any).error.code).toBe("forbidden");
  expect(callsOf(h.broker, "shred").length).toBe(shreds);
  expect((await connectionRow(h, ws.body.connection_id)).state).toBe("active");

  // The callback for a workspace connection the owner started: refused before the state is spent.
  const pending = await createConnection(h, owner, { provider: "google_sheets", adapter: "openapi", personal: false });
  expect(pending.res.status).toBe(201);
  const state = new URL(pending.body.authorize_url).searchParams.get("state")!;
  const q = new URLSearchParams({ state, code: "code-aud" });
  const cb = await h.req(`/v1/connections/callback?${q}`, { cookie: auditor.cookie });
  expect(cb.status).toBe(403);
  expect(((await cb.json()) as any).error.code).toBe("forbidden");
  expect((await connectionRow(h, pending.body.connection_id)).state).toBe("needs_reauth");
  const ok = await h.req(`/v1/connections/callback?${q}`, { cookie: owner.cookie });
  expect(ok.status).toBe(302);
});

// ---- 3. workspace connections are deleted by owner or admin only --------------------------------------------------

test("CONNECTION: a plain member cannot DELETE a workspace connection; the owner can", async () => {
  const owner = await session(h, user("wsdel-owner"));
  const member = await joinTenant(owner, "wsdel-member", "member");
  const ws = await createConnection(h, owner, { ...stripe("rk_test_wsdel"), personal: false });
  expect(ws.res.status).toBe(201);
  const id = ws.body.connection_id as string;
  const shredsFor = () => callsOf(h.broker, "shred").filter((c) => (c.input as any).connection_id === id).length;

  const del = await h.req(`/v1/connections/${id}`, { method: "DELETE", cookie: member.cookie, csrf: member.csrf });
  expect(del.status).toBe(403);
  expect(((await del.json()) as any).error.code).toBe("forbidden");
  expect(shredsFor()).toBe(0);
  expect((await connectionRow(h, id)).state).toBe("active");

  const byOwner = await h.req(`/v1/connections/${id}`, { method: "DELETE", cookie: owner.cookie, csrf: owner.csrf });
  expect(byOwner.status).toBe(204);
  expect(shredsFor()).toBe(1);
  expect((await connectionRow(h, id)).state).toBe("revoked");
});

// ---- 4. a DELETE during POST is not undone ------------------------------------------------------------------------

test("CONNECTION: a connection revoked while its POST runs is not reactivated", async () => {
  const s = await session(h, user("race-delete"));
  const { tenantId } = ids(s);
  let revokedId: string | undefined;
  h.broker.onNext("putApiKey", async (input) => {
    revokedId = (input as any).connection_id as string;
    const del = await h.req(`/v1/connections/${revokedId}`, { method: "DELETE", cookie: s.cookie, csrf: s.csrf });
    expect(del.status).toBe(204);
  });
  const r = await createConnection(h, s, stripe("rk_test_race_delete"));
  expect(r.res.status).toBe(409);
  expect(r.body.error.code).toBe("state_conflict");
  expect(revokedId).toBeDefined();
  const row = await connectionRow(h, revokedId!);
  expect(row.state).toBe("revoked");
  expect(row.account_hash).toBeNull();
  expect(await pinRows(h, tenantId, revokedId!)).toEqual([]);
  // The key the broker stored after the DELETE's shred is shredded again.
  const shreds = callsOf(h.broker, "shred").filter((c) => (c.input as any).connection_id === revokedId);
  expect(shreds.length).toBe(2);
  const putIndex = h.broker.calls.findIndex((c) => c.method === "putApiKey" && (c.input as any).connection_id === revokedId);
  const lastShred = h.broker.calls.findLastIndex((c) => c.method === "shred" && (c.input as any).connection_id === revokedId);
  expect(lastShred).toBeGreaterThan(putIndex);
});

// ---- 5 and 6. idempotency ---------------------------------------------------------------------------------------

test("CONNECTION: two concurrent POSTs with one Idempotency-Key give one connection and never a 500", async () => {
  const s = await session(h, user("idem-race"));
  for (let i = 0; i < 5; i++) {
    const key = ulid();
    const body = stripe(`rk_test_race_${i}`);
    const [a, b] = await Promise.all([
      createConnection(h, s, body, { headers: { "idempotency-key": key } }),
      createConnection(h, s, body, { headers: { "idempotency-key": key } }),
    ]);
    const statuses = [a.res.status, b.res.status].sort();
    // Overlapping: one 201 and one 409. Serialized (the first finished before the second began): a replay of the
    // same 201. Never 500, and one connection per key either way.
    if (statuses[1] === 409) {
      expect(statuses).toEqual([201, 409]);
      const conflict = a.res.status === 409 ? a : b;
      expect(conflict.body.error.code).toBe("idempotency_conflict");
    } else {
      expect(statuses).toEqual([201, 201]);
      expect(a.body).toEqual(b.body);
    }
  }
  expect(await countRows("select count(*)::int as n from connections where tenant_id = $1", [ids(s).tenantId])).toBe(5);
});

test("CONNECTION: an Idempotency-Key is bound to the member who used it", async () => {
  const owner = await session(h, user("idem-owner"));
  const other = await joinTenant(owner, "idem-other", "member");
  const key = ulid();
  const body = stripe("rk_test_idem_member");
  const a = await createConnection(h, owner, body, { headers: { "idempotency-key": key } });
  expect(a.res.status).toBe(201);
  const puts = callsOf(h.broker, "putApiKey").length;
  const b = await createConnection(h, other, body, { headers: { "idempotency-key": key } });
  expect(b.res.status).toBe(409);
  expect(b.body.error.code).toBe("idempotency_conflict");
  expect(b.text).not.toContain(a.body.connection_id);
  expect(callsOf(h.broker, "putApiKey").length).toBe(puts);
});

test("CONNECTION: a replay with the same Idempotency-Key and body returns the first 201; another body is 409", async () => {
  const s = await session(h, user("idem-replay"));
  const { tenantId } = ids(s);
  const key = ulid();
  const body = stripe("rk_test_replay");
  const first = await createConnection(h, s, body, { headers: { "idempotency-key": key } });
  expect(first.res.status).toBe(201);
  const puts = callsOf(h.broker, "putApiKey").length;
  const again = await createConnection(h, s, body, { headers: { "idempotency-key": key } });
  expect(again.res.status).toBe(201);
  expect(again.body).toEqual(first.body);
  expect(callsOf(h.broker, "putApiKey").length).toBe(puts);
  expect(await countRows("select count(*)::int as n from connections where tenant_id = $1", [tenantId])).toBe(1);

  const other = await createConnection(h, s, { ...body, personal: false }, { headers: { "idempotency-key": key } });
  expect(other.res.status).toBe(409);
  expect(other.body.error.code).toBe("idempotency_conflict");
  expect(await countRows("select count(*)::int as n from connections where tenant_id = $1", [tenantId])).toBe(1);
});

// ---- 7. coverage gaps -------------------------------------------------------------------------------------------

test("CONNECTION: a plain member does not see another member's personal connection; the owner does", async () => {
  const owner = await session(h, user("vis-owner"));
  const m1 = await joinTenant(owner, "vis-m1", "member");
  const m2 = await joinTenant(owner, "vis-m2", "member");
  const c = await createConnection(h, m1, stripe("rk_test_vis"));
  expect(c.res.status).toBe(201);
  const id = c.body.connection_id as string;

  const list2 = await h.req("/v1/connections", { cookie: m2.cookie });
  expect(list2.status).toBe(200);
  expect(((await list2.json()) as any[]).map((i) => i.connection_id)).not.toContain(id);
  expect((await h.req(`/v1/connections/${id}/tools`, { cookie: m2.cookie })).status).toBe(404);
  const shreds = callsOf(h.broker, "shred").length;
  expect((await h.req(`/v1/connections/${id}`, { method: "DELETE", cookie: m2.cookie, csrf: m2.csrf })).status).toBe(404);
  expect(callsOf(h.broker, "shred").length).toBe(shreds);

  const listOwner = await h.req("/v1/connections", { cookie: owner.cookie });
  expect(((await listOwner.json()) as any[]).map((i) => i.connection_id)).toContain(id);
  expect((await h.req(`/v1/connections/${id}/tools`, { cookie: owner.cookie })).status).toBe(200);
  const list1 = await h.req("/v1/connections", { cookie: m1.cookie });
  expect(((await list1.json()) as any[]).map((i) => i.connection_id)).toContain(id);
});

test("CONNECTION: a plain member POST with personal false is 403 forbidden", async () => {
  const owner = await session(h, user("ws-plain-owner"));
  const member = await joinTenant(owner, "ws-plain-member", "member");
  const before = h.broker.calls.length;
  const r = await createConnection(h, member, { ...stripe("rk_test_ws_plain"), personal: false });
  expect(r.res.status).toBe(403);
  expect(r.body.error.code).toBe("forbidden");
  expect(h.broker.calls.length).toBe(before);
});

test("CONNECTION: the callback with an unknown or spent state is 400 invalid_request", async () => {
  const s = await session(h, user("cb-state"));
  const unknown = await h.req(`/v1/connections/callback?${new URLSearchParams({ state: "not-a-known-state", code: "c" })}`, { cookie: s.cookie });
  expect(unknown.status).toBe(400);
  expect(((await unknown.json()) as any).error.code).toBe("invalid_request");

  const f = await connectOAuth(h, s, "google_calendar", "openapi");
  expect(f.callback.status).toBe(302);
  const again = await h.req(`/v1/connections/callback?${new URLSearchParams({ state: f.state, code: "c2" })}`, { cookie: s.cookie });
  expect(again.status).toBe(400);
  expect(((await again.json()) as any).error.code).toBe("invalid_request");
  expect((await connectionRow(h, f.connectionId)).state).toBe("active");
  expect((await auditActions(h, ids(s).tenantId, f.connectionId)).filter((a) => a === "connection.activated").length).toBe(1);
});

test("CONNECTION: POST with a workspace of the same tenant the member is not in is 400", async () => {
  const owner = await session(h, user("ws-other-owner"));
  const member = await joinTenant(owner, "ws-other-member", "member");
  const otherWs = uuidv7();
  await h.fx.admin.query("insert into workspaces (tenant_id, id, name) values ($1, $2, 'Other')", [ids(owner).tenantId, otherWs]);
  const before = h.broker.calls.length;
  const r = await createConnection(h, member, { ...stripe("rk_test_ws_other"), workspace_id: otherWs });
  expect(r.res.status).toBe(400);
  expect(r.body.error.code).toBe("invalid_request");
  expect(h.broker.calls.length).toBe(before);
});
