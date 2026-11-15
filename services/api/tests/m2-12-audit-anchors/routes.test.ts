import { afterAll, beforeAll, expect, test } from "bun:test";
import { AuditEventSchema, AuditVerifyResultSchema } from "@offload/contracts";
import { appendAudit, withTenant } from "@offload/db";
import { makeHarness, session, user, type AuditHarness } from "./harness.ts";

let h: AuditHarness;
beforeAll(async () => {
  h = await makeHarness();
});
afterAll(async () => {
  await h?.close();
});

type S = Awaited<ReturnType<typeof session>>;
const tenantOf = (s: S) => s.me.tenant.id as string;
const memberOf = (s: S) => s.me.member.id as string;
const setRole = (s: S, role: string) =>
  h.fx.admin.query("update members set tenant_role = $3 where tenant_id = $1 and id = $2", [tenantOf(s), memberOf(s), role]);
const ctxOf = (s: S) => ({ tenantId: tenantOf(s), principalId: memberOf(s), memberId: memberOf(s), tenantRole: "owner" as const });
const eventCount = async (s: S) => Number((await h.fx.admin.query("select count(*) as n from audit_events where tenant_id = $1", [tenantOf(s)])).rows[0].n);

test("VERIFY: GET /v1/audit-events/verify returns ok, checked and first_bad_seq", async () => {
  const s = await session(h, user("verify"));
  const before = await eventCount(s);
  const ok = await h.req("/v1/audit-events/verify", { cookie: s.cookie });
  expect(ok.status).toBe(200);
  const body = AuditVerifyResultSchema.parse(await ok.json());
  expect(body).toEqual({ ok: true, checked: before });
  expect("first_bad_seq" in body).toBe(false);
  // The run is audited with ok and checked in its details.
  const ev = (await h.fx.admin.query("select details, principal_id from audit_events where tenant_id = $1 and action = 'audit.verified'", [tenantOf(s)])).rows;
  expect(ev).toEqual([{ details: { ok: true, checked: before }, principal_id: memberOf(s) }]);

  // Edit an event as the migrator: the next run names the first bad event and the reason.
  const c = await h.fx.migrator.connect();
  try {
    await c.query("begin");
    await c.query("select set_config('app.tenant_id', $1, true)", [tenantOf(s)]);
    await c.query("alter table audit_events disable trigger append_only_rows");
    await c.query("update audit_events set details = '{\"x\": 1}' where tenant_id = $1 and seq = 1", [tenantOf(s)]);
    await c.query("alter table audit_events enable trigger append_only_rows");
    await c.query("commit");
  } finally {
    c.release();
  }
  const bad = await h.req("/v1/audit-events/verify", { cookie: s.cookie });
  expect(bad.status).toBe(200);
  expect(AuditVerifyResultSchema.parse(await bad.json())).toEqual({ ok: false, checked: before + 1, first_bad_seq: 1, reason: "hash_mismatch" });
  expect((await h.req("/v1/audit-events/verify")).status).toBe(401);
});

test("VERIFY: a member role gets 403 and an auditor gets the result", async () => {
  const s = await session(h, user("roles"));
  await setRole(s, "member");
  for (const path of ["/v1/audit-events/verify", "/v1/audit-events"]) {
    const res = await h.req(path, { cookie: s.cookie });
    expect(res.status).toBe(403);
    expect(((await res.json()) as any).error.code).toBe("forbidden");
  }
  await setRole(s, "auditor");
  const res = await h.req("/v1/audit-events/verify", { cookie: s.cookie });
  expect(res.status).toBe(200);
  expect(AuditVerifyResultSchema.parse(await res.json()).ok).toBe(true);
  await setRole(s, "admin");
  expect((await h.req("/v1/audit-events", { cookie: s.cookie })).status).toBe(200);
});

test("VERIFY: GET /v1/audit-events pages newest first with next_cursor and reads only its own tenant", async () => {
  const a = await session(h, user("page-a"));
  const b = await session(h, user("page-b"));
  await withTenant(h.fx.app, ctxOf(a), async (tx) => {
    for (let i = 0; i < 24; i++) await appendAudit(tx, { principalId: memberOf(a), action: "batch.committed", subjectType: "batch", subjectId: `b-${i}`, details: { i } });
  });
  await withTenant(h.fx.app, ctxOf(b), (tx) => appendAudit(tx, { principalId: memberOf(b), action: "batch.committed", subjectId: "other", details: {} }));
  const total = await eventCount(a);

  const seen: number[] = [];
  let cursor: string | null = null;
  let pages = 0;
  do {
    const q: string = `limit=10${cursor ? `&cursor=${encodeURIComponent(cursor)}` : ""}`;
    const res = await h.req(`/v1/audit-events?${q}`, { cookie: a.cookie });
    expect(res.status).toBe(200);
    const body = (await res.json()) as { items: unknown[]; next_cursor: string | null };
    expect(body.items.length).toBeLessThanOrEqual(10);
    for (const raw of body.items) {
      const e = AuditEventSchema.parse(raw);
      expect("tenant_id" in e).toBe(false);
      seen.push(e.seq);
    }
    cursor = body.next_cursor;
    pages++;
  } while (cursor && pages < 10);
  expect(pages).toBe(Math.ceil(total / 10));
  expect(cursor).toBeNull();
  expect(seen).toEqual(Array.from({ length: total }, (_, i) => total - i)); // newest first, no gaps, no repeats
  // Nothing from the other tenant: its event has subject_id "other".
  const all = (await (await h.req("/v1/audit-events?limit=200", { cookie: a.cookie })).json()) as { items: { subject_id: string | null }[] };
  expect(all.items.some((e) => e.subject_id === "other")).toBe(false);
  expect(all.items.length).toBe(total);
  for (const bad of ["limit=201", "limit=0", "limit=x", "cursor=abc"]) {
    expect((await h.req(`/v1/audit-events?${bad}`, { cookie: a.cookie })).status).toBe(400);
  }
});
