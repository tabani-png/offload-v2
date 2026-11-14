import { afterAll, beforeAll, expect, test } from "bun:test";
import { sha256Hex } from "@offload/contracts";
import {
  AuditEventError, appendAudit, setMemberRole, ulid, uuidv7, verifyAuditChain, withTenant, withTransaction, createPersonalTenant,
  LastOwnerError, type TenantContext,
} from "../../src/index.ts";
import { assertDisposableDatabase, pgTenantFixture, seedTenantRows, type PgTenantFixture } from "@offload/testkit";

// Findings from the m1-03 review gate, each pinned by a test.

let fx: PgTenantFixture;
beforeAll(async () => {
  fx = await pgTenantFixture({ appPoolSize: 6 });
  await seedTenantRows(fx);
});
afterAll(async () => {
  await fx?.close();
});

const fail = (p: Promise<unknown>) => p.then(() => null, (e: Error) => e);
const retentionCtx = (tenantId: string): TenantContext => ({ tenantId, principalId: "retention", memberId: null, tenantRole: "service", memberScope: "tenant" });

test("ROLE: SECURITY DEFINER functions cannot be steered by a temp table", async () => {
  const defs = (await fx.admin.query(
    "select proname, proconfig from pg_proc where pronamespace = 'public'::regnamespace and prosecdef order by 1",
  )).rows;
  expect(defs.length).toBeGreaterThanOrEqual(8);
  for (const d of defs) expect({ f: d.proname, c: d.proconfig }).toEqual({ f: d.proname, c: ["search_path=pg_catalog, public, pg_temp"] });
  // offload_retention tries to shadow observations_default with a temp table and get a row into tenant B.
  const c = await fx.retention.connect();
  const objectId = ulid();
  try {
    await c.query("begin");
    const made = await fail(c.query("create temp table observations_default (like public.observations)"));
    if (made === null) {
      await c.query("grant all on observations_default to offload_migrator");
      await c.query(
        `insert into observations_default (tenant_id, device_id, object_id, day, member_id, ts, kind)
         values ($1, $2, $3, '2032-05-05', $4, '2032-05-05T09:00:00Z', 'focus')`,
        [fx.b.tenantId, fx.b.devices.owner, objectId, fx.b.owner],
      );
      await c.query("select set_config('app.tenant_id', $1, true)", [fx.a.tenantId]);
      await c.query("select * from ensure_partitions('2032-05-05', 1)");
      await c.query("commit");
    } else {
      expect(made.message).toMatch(/permission denied/);
      await c.query("rollback");
    }
  } finally {
    c.release();
  }
  const n = (await fx.admin.query("select count(*)::int as n from public.observations where object_id = $1", [objectId])).rows[0].n;
  expect(n).toBe(0);
});

test("ROLE: withTenant takes lower-case ids only and appendAudit uses the canonical tenant id", async () => {
  const ctx = fx.ctx(fx.a, fx.a.owner);
  const upper = await fail(withTenant(fx.app, { ...ctx, tenantId: ctx.tenantId.toUpperCase() }, async () => 1));
  expect(upper).toBeInstanceOf(TypeError);
  const upperMember = await fail(withTenant(fx.app, { ...ctx, memberId: fx.a.owner.toUpperCase() }, async () => 1));
  expect(upperMember).toBeInstanceOf(TypeError);
  for (const bad of [{ principalId: "two words" }, { principalId: "" }, { tenantRole: "root" }]) {
    const err = await fail(withTenant(fx.app, { ...ctx, ...bad } as TenantContext, async () => 1));
    expect(err).toBeInstanceOf(TypeError);
  }
  // A hand-set upper-case setting still chains under the canonical id.
  await withTransaction(fx.app, async (tx) => {
    await tx.query("select set_config('app.tenant_id', $1, true)", [fx.a.tenantId.toUpperCase()]);
    const row = await appendAudit(tx, { principalId: fx.a.owner, action: "person.read", details: {} });
    expect(row.tenant_id).toBe(fx.a.tenantId);
  });
  expect(await withTenant(fx.app, ctx, (tx) => verifyAuditChain(tx))).toMatchObject({ ok: true });
});

test("AUDIT: offload_retention deletes only the oldest anchored audit rows", async () => {
  const t = await withTransaction(fx.app, (tx) => createPersonalTenant(tx, { idpSubject: `oidc|${uuidv7()}`, email: "r@example.test" }));
  const ctx: TenantContext = { tenantId: t.tenantId, principalId: t.memberId, memberId: t.memberId, tenantRole: "owner" };
  await withTenant(fx.app, ctx, async (tx) => {
    for (let i = 0; i < 4; i++) await appendAudit(tx, { principalId: t.memberId, action: "batch.committed", details: { i } });
  });
  const del = (sql: string) => fail(withTenant(fx.retention, retentionCtx(t.tenantId), (tx) => tx.query(sql)));
  // No anchor yet: nothing may go.
  expect((await del("delete from audit_events where seq = 1"))?.message).toMatch(/append_only/);
  const head = (await fx.admin.query("select seq, hash from audit_events where tenant_id = $1 and seq = 3", [t.tenantId])).rows[0];
  await withTenant(fx.app, ctx, (tx) => tx.query("insert into audit_anchors (tenant_id, seq, head_hash, signature, key_id) values ($1, 3, $2, 'sig', 'k')", [t.tenantId, head.hash]));
  // The chain head (seq 5) and anchored rows that are not the oldest stay.
  expect((await del("delete from audit_events where seq = 5"))?.message).toMatch(/append_only/);
  expect((await del("delete from audit_events where seq = 2"))?.message).toMatch(/append_only/);
  expect((await del("delete from audit_events where seq = 3"))?.message).toMatch(/append_only/);
  // Oldest first, strictly below the latest anchor: allowed.
  expect(await del("delete from audit_events where seq = 1")).toBeNull();
  expect(await del("delete from audit_events where seq = 2")).toBeNull();
  // The only anchor stays.
  expect((await del("delete from audit_anchors"))?.message).toMatch(/append_only/);
  const left = (await fx.admin.query("select seq from audit_events where tenant_id = $1 order by seq", [t.tenantId])).rows.map((r) => Number(r.seq));
  expect(left).toEqual([3, 4, 5]);
});

test("ROLE: resolvers skip departed and frozen members and deleted tenants", async () => {
  const c = await fx.app.connect();
  const resolveAll = async (t: typeof fx.a) => [
    (await c.query("select * from auth_resolve_identity($1)", [t.idpSubject])).rowCount,
    (await c.query("select * from auth_resolve_session($1)", [t.seeds.sessionTokenSha256])).rowCount,
    (await c.query("select * from auth_resolve_pat($1)", [t.seeds.patTokenSha256])).rowCount,
    (await c.query("select * from auth_resolve_device($1)", [t.devices.owner])).rowCount,
    (await c.query("select * from auth_resolve_enrollment_code($1)", [t.seeds.enrollmentCodeSha256])).rowCount,
  ];
  try {
    expect(await resolveAll(fx.a)).toEqual([1, 1, 1, 1, 1]);
    for (const state of ["frozen", "departed"]) {
      await fx.admin.query("update members set state = $2 where id = $1", [fx.a.owner, state]);
      expect({ state, n: await resolveAll(fx.a) }).toEqual({ state, n: [0, 0, 0, 0, 0] });
    }
    await fx.admin.query("update members set state = 'active' where id = $1", [fx.a.owner]);
    expect(await resolveAll(fx.a)).toEqual([1, 1, 1, 1, 1]);
    await fx.admin.query("update tenants set deleted_at = now() where id = $1", [fx.b.tenantId]);
    expect(await resolveAll(fx.b)).toEqual([0, 0, 0, 0, 0]);
    const listed = (await fx.jobs.query("select * from jobs_list_tenants()")).rows.map((r) => r.tenant_id);
    expect(listed).toContain(fx.a.tenantId);
    expect(listed).not.toContain(fx.b.tenantId);
  } finally {
    await fx.admin.query("update tenants set deleted_at = null where id = $1", [fx.b.tenantId]);
    c.release();
  }
});

test("ROLE: two owners demoted at once leave one owner", async () => {
  const t = await withTransaction(fx.app, (tx) => createPersonalTenant(tx, { idpSubject: `oidc|${uuidv7()}`, email: "o@example.test" }));
  const second = uuidv7();
  const ctx: TenantContext = { tenantId: t.tenantId, principalId: t.memberId, memberId: t.memberId, tenantRole: "owner" };
  await withTenant(fx.app, ctx, (tx) => tx.query(
    "insert into members (tenant_id, id, email, email_hash, tenant_role, state) values ($1, $2, 'p@example.test', $3, 'owner', 'active')",
    [t.tenantId, second, sha256Hex("p@example.test")]));
  // Each transaction holds its row lock long enough for the other to start.
  const demote = (id: string) => withTenant(fx.app, ctx, async (tx) => {
    await setMemberRole(tx, id, "member");
    await tx.query("select pg_sleep(0.1)");
  });
  const results = await Promise.allSettled([demote(t.memberId), demote(second)]);
  expect(results.filter((r) => r.status === "fulfilled")).toHaveLength(1);
  const rejected = results.find((r) => r.status === "rejected") as PromiseRejectedResult;
  expect(rejected.reason).toBeInstanceOf(LastOwnerError);
  const owners = (await fx.admin.query("select count(*)::int as n from members where tenant_id = $1 and tenant_role = 'owner' and state = 'active'", [t.tenantId])).rows[0].n;
  expect(owners).toBe(1);
});

test("AUDIT: details over 2048 bytes in total are refused", async () => {
  const words = Array.from({ length: 40 }, (_, i) => `word${i}`.padEnd(60, "x"));
  const err = await fail(withTenant(fx.app, fx.ctx(fx.a, fx.a.owner), (tx) => appendAudit(tx, { principalId: fx.a.owner, action: "person.read", details: { words } })));
  expect(err).toBeInstanceOf(AuditEventError);
});

test("MIGRATE: freshDatabase refuses a database that is not marked disposable", async () => {
  const ok = await fail(assertDisposableDatabase(fx.admin));
  expect(ok).toBeNull();
  const c = await fx.admin.connect();
  try {
    const db = (await c.query("select current_database() as d")).rows[0].d as string;
    const before = (await c.query("select shobj_description(oid, 'pg_database') as d from pg_database where datname = $1", [db])).rows[0].d;
    if (!/(^|_)test$/.test(db)) {
      await c.query(`comment on database "${db}" is 'not marked'`);
      try {
        expect((await fail(assertDisposableDatabase(fx.admin)))?.message).toMatch(/disposable/);
      } finally {
        await c.query(`comment on database "${db}" is ${before === null ? "null" : `'${String(before).replace(/'/g, "''")}'`}`);
      }
    }
  } finally {
    c.release();
  }
});
