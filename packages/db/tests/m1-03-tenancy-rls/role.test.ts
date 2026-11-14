import { afterAll, beforeAll, expect, test } from "bun:test";
import { sha256Hex } from "@offload/contracts";
import {
  APPEND_ONLY_TABLES, LastOwnerError, bootstrapRoles, NetworkIoInTransactionError, createPersonalTenant, setMemberRole,
  setMemberState, uuidv7, withTenant, withTransaction,
} from "../../src/index.ts";
import { pgTenantFixture, seedTenantRows, type PgTenantFixture } from "@offload/testkit";

let fx: PgTenantFixture;
beforeAll(async () => {
  fx = await pgTenantFixture();
  await seedTenantRows(fx);
});
afterAll(async () => {
  await fx?.close();
});

const fail = (p: Promise<unknown>) => p.then(() => null, (e: Error) => e);

test("ROLE: offload_app cannot DELETE or UPDATE audit_events, audit_anchors or purge_log", async () => {
  expect([...APPEND_ONLY_TABLES].sort()).toEqual(["audit_anchors", "audit_events", "purge_log"]);
  const ctx = fx.ctx(fx.a, fx.a.owner);
  for (const table of APPEND_ONLY_TABLES) {
    const n = await withTenant(fx.app, ctx, async (tx) => (await tx.query(`select count(*)::int as n from ${table}`)).rows[0].n);
    expect({ table, seeded: n > 0 }).toEqual({ table, seeded: true });
    for (const sql of [`delete from ${table}`, `update ${table} set tenant_id = tenant_id`, `truncate ${table}`]) {
      const err = await fail(withTenant(fx.app, ctx, (tx) => tx.query(sql)));
      expect({ sql, err: err?.message ?? "" }).toEqual({ sql, err: expect.stringMatching(/permission denied|append_only/) });
    }
    // Even the owner role is stopped by the trigger.
    const c = await fx.migrator.connect();
    try {
      const err = await fail(c.query(`delete from ${table} where tenant_id = $1`, [fx.a.tenantId]));
      expect(err?.message).toMatch(/append_only/);
      const terr = await fail(c.query(`truncate ${table} cascade`));
      expect(terr?.message).toMatch(/append_only/);
    } finally {
      c.release();
    }
  }
  // offload_retention may delete (past retention; the workflow picks rows in m3-01).
  const del = await withTenant(fx.retention, { ...ctx, principalId: "retention", memberId: null, tenantRole: "service" }, async (tx) =>
    (await tx.query("delete from purge_log where tenant_id = $1", [fx.a.tenantId])).rowCount);
  expect(del).toBeGreaterThan(0);
  const upd = await fail(withTenant(fx.retention, { ...ctx, principalId: "retention", memberId: null, tenantRole: "service" }, (tx) =>
    tx.query("update audit_events set rule_id = 'x'")));
  expect(upd?.message).toMatch(/permission denied/);
});

test("ROLE: offload_app has no BYPASSRLS and owns no table", async () => {
  const roles = (await fx.admin.query(
    "select rolname, rolbypassrls, rolsuper, rolcreaterole, rolcreatedb from pg_roles where rolname in ('offload_app','offload_jobs','offload_retention') order by 1",
  )).rows;
  expect(roles.map((r) => r.rolname)).toEqual(["offload_app", "offload_jobs", "offload_retention"]);
  for (const r of roles) expect({ ...r, rolname: undefined }).toEqual({ rolname: undefined, rolbypassrls: false, rolsuper: false, rolcreaterole: false, rolcreatedb: false });
  for (const role of ["offload_app", "offload_jobs", "offload_retention"]) {
    const owned = (await fx.admin.query(
      `select c.relname from pg_class c where pg_get_userbyid(c.relowner) = $1
       union all select p.proname from pg_proc p where pg_get_userbyid(p.proowner) = $1
       union all select n.nspname from pg_namespace n where pg_get_userbyid(n.nspowner) = $1`,
      [role],
    )).rows;
    expect({ role, owned }).toEqual({ role, owned: [] });
  }
  const notMigrator = (await fx.admin.query(
    `select c.relname from pg_class c join pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'public' and pg_get_userbyid(c.relowner) <> 'offload_migrator'`,
  )).rows;
  expect(notMigrator).toEqual([]);
});

test("ROLE: resolver functions return ids only and nothing for unknown keys", async () => {
  const expected: Record<string, [string, string[]]> = {
    auth_resolve_identity: ["text", ["tenant_id", "member_id"]],
    auth_resolve_session: ["text", ["tenant_id", "member_id", "tenant_role", "expires_at", "last_seen_at"]],
    auth_resolve_device: ["uuid", ["tenant_id", "member_id", "revoked_at"]],
    auth_resolve_enrollment_code: ["text", ["tenant_id", "member_id", "code_challenge", "redirect_uri", "expires_at", "used_at"]],
    auth_resolve_pat: ["text", ["tenant_id", "member_id", "scopes", "revoked_at"]],
  };
  for (const [fn, [argType, cols]] of Object.entries(expected)) {
    const meta = (await fx.admin.query(
      `select p.prosecdef, pg_get_userbyid(p.proowner) as owner, p.proconfig, pg_get_function_identity_arguments(p.oid) as args,
         has_function_privilege('offload_app', p.oid, 'execute') as app, has_function_privilege('offload_jobs', p.oid, 'execute') as jobs
       from pg_proc p where p.proname = $1 and p.pronamespace = 'public'::regnamespace`,
      [fn],
    )).rows;
    expect(meta).toHaveLength(1);
    expect(meta[0]).toEqual({ prosecdef: true, owner: "offload_migrator", proconfig: ["search_path=pg_catalog, public, pg_temp"], args: expect.stringContaining(argType), app: true, jobs: false });
    const unknown = argType === "uuid" ? uuidv7() : sha256Hex("unknown");
    const c = await fx.app.connect();
    try {
      const res = await c.query(`select * from ${fn}($1)`, [fn === "auth_resolve_identity" ? "unknown-subject" : unknown]);
      expect(res.fields.map((f) => f.name)).toEqual(cols);
      expect(res.rows).toEqual([]);
    } finally {
      c.release();
    }
  }
  // Known keys resolve, from a connection with no tenant set.
  const c = await fx.app.connect();
  try {
    const one = async (sql: string, arg: string) => (await c.query(sql, [arg])).rows;
    expect(await one("select * from auth_resolve_identity($1)", fx.a.idpSubject)).toEqual([{ tenant_id: fx.a.tenantId, member_id: fx.a.owner }]);
    const s = await one("select * from auth_resolve_session($1)", fx.a.seeds.sessionTokenSha256);
    expect(s).toHaveLength(1);
    expect(s[0]).toMatchObject({ tenant_id: fx.a.tenantId, member_id: fx.a.owner, tenant_role: "owner" });
    expect(await one("select * from auth_resolve_device($1)", fx.b.devices.member)).toEqual([{ tenant_id: fx.b.tenantId, member_id: fx.b.member, revoked_at: null }]);
    expect((await one("select * from auth_resolve_enrollment_code($1)", fx.b.seeds.enrollmentCodeSha256))[0]).toMatchObject({ tenant_id: fx.b.tenantId, used_at: null });
    expect((await one("select * from auth_resolve_pat($1)", fx.a.seeds.patTokenSha256))[0]).toMatchObject({ tenant_id: fx.a.tenantId, member_id: fx.a.owner, scopes: ["mcp"] });
  } finally {
    c.release();
  }
});

test("ROLE: offload_jobs can list tenants and claim outbox rows and nothing else", async () => {
  const c = await fx.jobs.connect();
  try {
    const tenants = (await c.query("select * from jobs_list_tenants()")).rows.map((r) => r.tenant_id).sort();
    expect(tenants).toEqual([fx.a.tenantId, fx.b.tenantId].sort());
    const claimed = (await c.query("select * from outbox_claim(10)"));
    expect(claimed.fields.map((f) => f.name)).toEqual(["tenant_id", "id"]);
    const pending = (await fx.admin.query(
      "select count(*)::int as n from events_outbox e where not exists (select 1 from outbox_deliveries d where d.event_id = e.id and d.consumer = 'workflow:outbox_dispatch')",
    )).rows[0].n;
    expect(pending).toBe(0);
    expect(claimed.rows.length).toBeGreaterThan(0);
    expect(new Set(claimed.rows.map((r) => r.tenant_id))).toEqual(new Set([fx.a.tenantId, fx.b.tenantId]));
    // A second claim finds nothing: claimed rows are marked in outbox_deliveries.
    expect((await c.query("select * from outbox_claim(10)")).rows).toEqual([]);
    const tables = (await fx.admin.query(
      "select c.relname from pg_class c join pg_namespace n on n.oid = c.relnamespace where n.nspname = 'public' and c.relkind in ('r','p')",
    )).rows.map((r) => r.relname as string);
    for (const t of tables) {
      const err = await fail(c.query(`select 1 from ${t} limit 1`));
      expect({ t, err: err?.message ?? "" }).toEqual({ t, err: expect.stringMatching(/permission denied/) });
    }
    for (const sql of [
      "select * from auth_resolve_identity('x')", "select * from ensure_partitions(current_date, 1)",
      "select apply_tenant_rls('tenants'::regclass)", "insert into events_outbox (tenant_id, id, type) values (gen_random_uuid(), gen_random_uuid(), 't')",
    ]) {
      const err = await fail(c.query(sql));
      expect({ sql, err: err?.message ?? "" }).toEqual({ sql, err: expect.stringMatching(/permission denied/) });
    }
  } finally {
    c.release();
  }
});

test("ROLE: createPersonalTenant makes one tenant, one workspace, one owner", async () => {
  const email = "  Person.One@Example.TEST ";
  const idpSubject = `oidc|${uuidv7()}`;
  const made = await withTransaction(fx.app, (tx) => createPersonalTenant(tx, { idpSubject, email }));
  const ctx = { tenantId: made.tenantId, principalId: made.memberId, memberId: made.memberId, tenantRole: "owner" as const };
  await withTenant(fx.app, ctx, async (tx) => {
    const t = (await tx.query("select id, kind from tenants")).rows;
    expect(t).toEqual([{ id: made.tenantId, kind: "personal" }]);
    expect((await tx.query("select id from workspaces")).rows).toEqual([{ id: made.workspaceId }]);
    const m = (await tx.query("select id, email, email_hash, tenant_role, state, idp_subject from members")).rows;
    expect(m).toEqual([{ id: made.memberId, email: email.trim(), email_hash: sha256Hex("person.one@example.test"), tenant_role: "owner", state: "active", idp_subject: idpSubject }]);
    expect((await tx.query("select workspace_id, member_id, workspace_role from workspace_members")).rows)
      .toEqual([{ workspace_id: made.workspaceId, member_id: made.memberId, workspace_role: "lead" }]);
    const audit = (await tx.query("select seq, action, subject_type, subject_id, principal_id, details from audit_events")).rows;
    expect(audit).toEqual([{ seq: "1", action: "tenant.created", subject_type: "tenant", subject_id: made.tenantId, principal_id: made.memberId, details: { workspace_id: made.workspaceId, member_id: made.memberId } }]);
  });
  // The email itself is not in the audit row.
  const raw = (await fx.admin.query("select details::text as d from audit_events where tenant_id = $1", [made.tenantId])).rows[0].d;
  expect(raw.toLowerCase()).not.toContain("example.test");
  const resolved = (await fx.app.query("select * from auth_resolve_identity($1)", [idpSubject])).rows;
  expect(resolved).toEqual([{ tenant_id: made.tenantId, member_id: made.memberId }]);
});

test("ROLE: removing the last owner throws LastOwnerError", async () => {
  const ctx = fx.ctx(fx.b, fx.b.owner);
  for (const change of [
    (tx: Parameters<typeof setMemberRole>[0]) => setMemberRole(tx, fx.b.owner, "admin"),
    (tx: Parameters<typeof setMemberRole>[0]) => setMemberState(tx, fx.b.owner, "departed"),
    (tx: Parameters<typeof setMemberRole>[0]) => setMemberState(tx, fx.b.owner, "frozen"),
  ]) {
    const err = await fail(withTenant(fx.app, ctx, change));
    expect(err).toBeInstanceOf(LastOwnerError);
    expect((err as LastOwnerError).code).toBe("last_owner");
  }
  // With a second active owner, the first may step down; then the second is the last one.
  await withTenant(fx.app, ctx, (tx) => setMemberRole(tx, fx.b.member, "owner"));
  await withTenant(fx.app, ctx, (tx) => setMemberRole(tx, fx.b.owner, "member"));
  const err = await fail(withTenant(fx.app, ctx, (tx) => setMemberState(tx, fx.b.member, "leaving")));
  expect(err).toBeInstanceOf(LastOwnerError);
  // Changes are audited; nothing changed by the refused calls.
  const rows = await withTenant(fx.app, ctx, async (tx) => (await tx.query("select id, tenant_role, state from members")).rows);
  const byId = Object.fromEntries(rows.map((r) => [r.id, `${r.tenant_role}/${r.state}`]));
  expect(byId).toEqual({ [fx.b.owner]: "member/active", [fx.b.member]: "owner/active" });
  const actions = await withTenant(fx.app, ctx, async (tx) => (await tx.query("select action from audit_events where action like 'member.%' order by seq")).rows.map((r) => r.action));
  expect(actions).toEqual(["member.role_changed", "member.role_changed"]);
  // Unknown member: not found, not a silent success.
  const missing = await fail(withTenant(fx.app, ctx, (tx) => setMemberRole(tx, fx.a.owner, "admin")));
  expect(missing?.message).toMatch(/member not found/);
});

test("ROLE: a fetch inside withTenant throws", async () => {
  const ctx = fx.ctx(fx.a, fx.a.owner);
  const id = uuidv7();
  const err = await fail(withTenant(fx.app, ctx, async (tx) => {
    await tx.query("insert into workspaces (tenant_id, id, name) values ($1, $2, 'w')", [fx.a.tenantId, id]);
    await fetch("http://127.0.0.1:9/never");
  }));
  expect(err).toBeInstanceOf(NetworkIoInTransactionError);
  // The transaction rolled back.
  const n = (await fx.admin.query("select count(*)::int as n from workspaces where id = $1", [id])).rows[0].n;
  expect(n).toBe(0);
  // Also from a nested async continuation started inside fn.
  const nested = await fail(withTenant(fx.app, ctx, async () => {
    await new Promise((r) => setTimeout(r, 1));
    await Promise.resolve().then(() => fetch("http://127.0.0.1:9/never"));
  }));
  expect(nested).toBeInstanceOf(NetworkIoInTransactionError);
  // fn gets a tx with query only: no release(), no connect().
  await withTenant(fx.app, ctx, async (tx) => {
    expect(Object.keys(tx)).toEqual(["query"]);
  });
  // withTenant sets every documented setting.
  const s = await withTenant(fx.app, { ...ctx, principalId: "p-1" }, async (tx) => (await tx.query(
    `select current_setting('app.tenant_id') t, current_setting('app.principal_id') p, current_setting('app.member_id') m,
            current_setting('app.tenant_role') r, current_setting('app.member_scope') s`,
  )).rows[0]);
  expect(s).toEqual({ t: fx.a.tenantId, p: "p-1", m: fx.a.owner, r: "owner", s: "member" });
});

test("ROLE: bootstrapRoles is idempotent and refuses to run as a role it manages", async () => {
  const admin = await fx.admin.connect();
  try {
    await bootstrapRoles(admin);
    await bootstrapRoles(admin);
  } finally {
    admin.release();
  }
  // Run as offload_migrator (in compose it is the container superuser) it would rewrite its own attributes.
  const c = await fx.migrator.connect();
  try {
    const err = await fail(bootstrapRoles(c));
    expect(err?.message).toMatch(/administrator/);
  } finally {
    c.release();
  }
});
