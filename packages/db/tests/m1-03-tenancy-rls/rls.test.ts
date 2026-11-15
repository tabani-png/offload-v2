import { afterAll, beforeAll, expect, test } from "bun:test";
import { MEMBER_ISOLATED_TABLES, RLS_GLOBAL_ALLOWLIST, uuidv7, withTenant } from "../../src/index.ts";
import { pgTenantFixture, seedTenantRows, type PgTenantFixture } from "@offload/testkit";

let fx: PgTenantFixture;
let tenantTables: string[];

beforeAll(async () => {
  fx = await pgTenantFixture();
  await seedTenantRows(fx);
  // Parent tables only: partitions are reached through their parent.
  tenantTables = (await fx.admin.query(
    `select c.relname as t from pg_class c join pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'public' and c.relkind in ('r','p') and not c.relispartition
       and c.relname <> all($1::text[]) order by 1`,
    [RLS_GLOBAL_ALLOWLIST],
  )).rows.map((r) => r.t as string);
});
afterAll(async () => {
  await fx?.close();
});

async function countAs(ctx: Parameters<typeof withTenant>[1], table: string): Promise<number> {
  return withTenant(fx.app, ctx, async (tx) => (await tx.query(`select count(*)::int as n from ${table}`)).rows[0].n as number);
}

test("RLS: every tenant table has FORCE ROW LEVEL SECURITY", async () => {
  expect([...RLS_GLOBAL_ALLOWLIST].sort()).toEqual(["license_state", "magic_links", "schema_migrations"]);
  const rows = (await fx.admin.query(
    `select c.relname, c.relrowsecurity, c.relforcerowsecurity, c.relispartition,
       exists (select 1 from pg_policy p where p.polrelid = c.oid and p.polname = 'tenant_isolation' and p.polpermissive) as has_policy
     from pg_class c join pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'public' and c.relkind in ('r','p')`,
  )).rows;
  expect(rows.some((r) => r.relispartition)).toBe(true); // partitions are in the set
  const bad = rows
    .filter((r) => !RLS_GLOBAL_ALLOWLIST.includes(r.relname))
    .filter((r) => !(r.relrowsecurity && r.relforcerowsecurity && r.has_policy))
    .map((r) => r.relname);
  expect(bad).toEqual([]);
  // Allowlisted tables hold no tenant_id.
  const leaking = (await fx.admin.query(
    `select table_name from information_schema.columns where table_schema = 'public' and column_name = 'tenant_id' and table_name = any($1::text[])`,
    [RLS_GLOBAL_ALLOWLIST],
  )).rows;
  expect(leaking).toEqual([]);
  // The policy expression is exactly the documented one.
  const qual = (await fx.admin.query(
    "select pg_get_expr(polqual, polrelid) as q, pg_get_expr(polwithcheck, polrelid) as w from pg_policy where polrelid = 'members'::regclass and polname = 'tenant_isolation'",
  )).rows[0];
  expect(qual.q).toContain("NULLIF(current_setting('app.tenant_id'::text, true), ''::text))::uuid");
  expect(qual.w).toBe(qual.q);
});

test("RLS: offload_app with tenant A reads zero rows of tenant B", async () => {
  expect(tenantTables.length).toBeGreaterThanOrEqual(20);
  for (const table of tenantTables) {
    const col = table === "tenants" ? "id" : "tenant_id";
    // Seeded: tenant B has rows in this table (checked as the superuser).
    const seeded = (await fx.admin.query(`select count(*)::int as n from ${table} where ${col} = $1`, [fx.b.tenantId])).rows[0].n;
    expect({ table, seeded: seeded > 0 }).toEqual({ table, seeded: true });
    const seen = await withTenant(fx.app, fx.ctx(fx.a, fx.a.owner, "tenant"), async (tx) =>
      (await tx.query(`select count(*)::int as n from ${table} where ${col} = $1`, [fx.b.tenantId])).rows[0].n as number);
    expect({ table, seen }).toEqual({ table, seen: 0 });
    const own = await withTenant(fx.app, fx.ctx(fx.a, fx.a.owner, "tenant"), async (tx) =>
      (await tx.query(`select count(*)::int as n from ${table} where ${col} = $1`, [fx.a.tenantId])).rows[0].n as number);
    expect({ table, own: own > 0 }).toEqual({ table, own: true });
  }
});

test("RLS: with app.tenant_id unset offload_app reads zero rows", async () => {
  const c = await fx.app.connect();
  try {
    for (const table of tenantTables) {
      const n = (await c.query(`select count(*)::int as n from ${table}`)).rows[0].n;
      expect({ table, n }).toEqual({ table, n: 0 });
    }
    // An empty setting is the same as unset.
    await c.query("begin");
    await c.query("select set_config('app.tenant_id', '', true), set_config('app.member_scope', 'tenant', true)");
    for (const table of tenantTables) {
      const n = (await c.query(`select count(*)::int as n from ${table}`)).rows[0].n;
      expect({ table, n }).toEqual({ table, n: 0 });
    }
    await c.query("rollback");
  } finally {
    c.release();
  }
});

test("RLS: inserting a row for another tenant fails WITH CHECK", async () => {
  const err = await withTenant(fx.app, fx.ctx(fx.a, fx.a.owner), (tx) =>
    tx.query("insert into workspaces (tenant_id, id, name) values ($1, $2, 'w')", [fx.b.tenantId, uuidv7()]),
  ).then(() => null, (e: Error) => e);
  expect(err?.message).toMatch(/row-level security/);
  // And moving an own row to another tenant fails too.
  const upd = await withTenant(fx.app, fx.ctx(fx.a, fx.a.owner), (tx) =>
    tx.query("update workspaces set tenant_id = $1 where tenant_id = $2", [fx.b.tenantId, fx.a.tenantId]),
  ).then(() => null, (e: Error) => e);
  expect(upd?.message).toMatch(/row-level security|foreign key/);
  // Member wall on insert: member A cannot write a row as member B of the same tenant.
  const mi = await withTenant(fx.app, fx.ctx(fx.a, fx.a.owner), (tx) =>
    tx.query("insert into exclusions (tenant_id, member_id, id, kind, value, source) values ($1, $2, $3, 'host', 'example.test', 'user')",
      [fx.a.tenantId, fx.a.member, uuidv7()]),
  ).then(() => null, (e: Error) => e);
  expect(mi?.message).toMatch(/row-level security/);
});

test("RLS: tenants is isolated by id", async () => {
  const rows = await withTenant(fx.app, fx.ctx(fx.a, fx.a.owner), async (tx) => (await tx.query("select id from tenants")).rows.map((r) => r.id));
  expect(rows).toEqual([fx.a.tenantId]);
  const other = await withTenant(fx.app, fx.ctx(fx.a, fx.a.owner), async (tx) =>
    (await tx.query("update tenants set name = 'x' where id = $1", [fx.b.tenantId])).rowCount);
  expect(other).toBe(0);
  const ins = await withTenant(fx.app, fx.ctx(fx.a, fx.a.owner), (tx) =>
    tx.query("insert into tenants (id, kind, name) values ($1, 'personal', 'p')", [uuidv7()]),
  ).then(() => null, (e: Error) => e);
  expect(ins?.message).toMatch(/row-level security/);
});

test("RLS: member B reads zero C1 rows of member A in the same tenant", async () => {
  expect([...MEMBER_ISOLATED_TABLES].sort()).toEqual(["exclusions", "imports", "observation_texts", "observations"]);
  // The list matches the tables that carry the restrictive policy (parents).
  const withPolicy = (await fx.admin.query(
    `select c.relname from pg_policy p join pg_class c on c.oid = p.polrelid
     where p.polname = 'member_isolation' and not p.polpermissive and not c.relispartition order by 1`,
  )).rows.map((r) => r.relname);
  expect(withPolicy).toEqual([...MEMBER_ISOLATED_TABLES].sort());
  for (const table of MEMBER_ISOLATED_TABLES) {
    const seededForA = (await fx.admin.query(`select count(*)::int as n from ${table} where member_id = $1`, [fx.a.owner])).rows[0].n;
    expect({ table, seededForA: seededForA > 0 }).toEqual({ table, seededForA: true });
    const seen = await withTenant(fx.app, fx.ctx(fx.a, fx.a.member), async (tx) =>
      (await tx.query(`select count(*)::int as n from ${table} where member_id = $1`, [fx.a.owner])).rows[0].n as number);
    expect({ table, seen }).toEqual({ table, seen: 0 });
    const own = await withTenant(fx.app, fx.ctx(fx.a, fx.a.member), async (tx) =>
      (await tx.query(`select count(*)::int as n, count(*) filter (where member_id <> $1)::int as others from ${table}`, [fx.a.member])).rows[0]);
    expect({ table, own: own.n > 0, others: own.others }).toEqual({ table, own: true, others: 0 });
  }
  // With no member set, MI tables are empty even with the tenant set.
  for (const table of MEMBER_ISOLATED_TABLES) {
    expect(await countAs({ tenantId: fx.a.tenantId, principalId: "service", memberId: null, tenantRole: "service" }, table)).toBe(0);
  }
});

test("RLS: member_scope tenant reads every member's rows", async () => {
  for (const table of MEMBER_ISOLATED_TABLES) {
    const members = await withTenant(fx.app, fx.ctx(fx.a, fx.a.member, "tenant"), async (tx) =>
      (await tx.query(`select distinct member_id from ${table}`)).rows.map((r) => r.member_id).sort());
    expect({ table, members }).toEqual({ table, members: [fx.a.owner, fx.a.member].sort() });
  }
  // member_scope does not cross the tenant wall.
  const obs = await withTenant(fx.app, fx.ctx(fx.a, fx.a.member, "tenant"), async (tx) =>
    (await tx.query("select count(*)::int as n from observations where tenant_id <> $1", [fx.a.tenantId])).rows[0].n);
  expect(obs).toBe(0);
  // Any other member_scope value is the member default.
  const c = await fx.app.connect();
  try {
    await c.query("begin");
    await c.query("select set_config('app.tenant_id', $1, true), set_config('app.member_id', $2, true), set_config('app.member_scope', 'TENANT', true)", [fx.a.tenantId, fx.a.member]);
    const n = (await c.query("select count(*)::int as n from observations where member_id = $1", [fx.a.owner])).rows[0].n;
    expect(n).toBe(0);
    await c.query("rollback");
  } finally {
    c.release();
  }
});
