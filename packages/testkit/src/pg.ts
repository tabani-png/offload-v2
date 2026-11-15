import { createHash, createHmac, pbkdf2Sync, randomBytes } from "node:crypto";
import { Pool, type ClientBase } from "pg";
import {
  ROLES, bootstrapRoles, createPersonalTenant, installNetworkGuard, migrate, registerBeforeCommit, ulid, uuidv7, withTenant,
  withTransaction, type MemberScope, type TenantContext, type Tx,
} from "@offload/db";
import { sha256Hex } from "@offload/contracts";

/**
 * Real-Postgres fixtures for m1-03 and later slices. Needs DATABASE_URL pointing at a Postgres 17 database this test
 * run may reset, as a role that can create roles (a superuser in development and CI). The URL is never printed.
 */

export function databaseUrl(): string {
  const url = process.env["DATABASE_URL"];
  if (!url) throw new Error("DATABASE_URL is required (Postgres 17): docker compose -f infra/docker-compose/compose.yaml up -d postgres");
  return url;
}

/**
 * The test-only login password of `role` on the cluster `url` points at: sha256 of the cluster address, the
 * administrator's credentials and the role name. It is never stored, differs per role, cannot be derived from the repo
 * alone, and is the same for every test process and database on one cluster (roles are cluster-wide; a random per-run
 * value would break a concurrent run). freshDatabase sets it; trust-auth clusters ignore it, password-auth clusters
 * (CI: scram-sha-256) need it. Never printed.
 */
export function testRolePassword(role: string, url: string = databaseUrl()): string {
  const u = new URL(url);
  const cluster = `${u.hostname}:${u.port}\0${decodeURIComponent(u.username)}\0${decodeURIComponent(u.password)}`;
  return createHash("sha256").update(`offload-testkit-role-password\0${cluster}\0${role}`).digest("hex");
}

/** The same database as another role, with that role's test password (see testRolePassword). */
export function roleUrl(role: string, url: string = databaseUrl()): string {
  const u = new URL(url);
  u.username = role;
  u.password = testRolePassword(role, url);
  return u.toString();
}

/**
 * Gives every role in ROLES its test password. Roles are cluster-wide and concurrent ALTER ROLEs on one role can fail
 * with "tuple concurrently updated", so the alter runs only when the stored SCRAM verifier does not already match.
 */
async function setTestRolePasswords(admin: ClientBase): Promise<void> {
  for (const role of Object.values(ROLES)) {
    const password = testRolePassword(role);
    const stored = (await admin.query("select rolpassword from pg_authid where rolname = $1", [role])).rows[0]?.rolpassword as string | null;
    if (stored && scramVerifies(stored, password)) continue;
    await admin.query(`alter role ${role} password '${password}'`); // hex only: safe to inline
  }
}

/** True when `password` matches a stored SCRAM-SHA-256 verifier (`SCRAM-SHA-256$iter:salt$StoredKey:ServerKey`). */
function scramVerifies(stored: string, password: string): boolean {
  const m = /^SCRAM-SHA-256\$(\d+):([^$]+)\$([^:]+):.+$/.exec(stored);
  if (!m) return false;
  const salted = pbkdf2Sync(password, Buffer.from(m[2]!, "base64"), Number(m[1]), 32, "sha256");
  const clientKey = createHmac("sha256", salted).update("Client Key").digest();
  return createHash("sha256").update(clientKey).digest("base64") === m[3];
}

/**
 * Drops and recreates schema public (when `reset`), creates the roles, and runs every migration as offload_migrator.
 * Schema `durable` is left alone. Returns the migration versions applied.
 */
export async function freshDatabase(opts: { reset?: boolean } = {}): Promise<string[]> {
  const admin = new Pool({ connectionString: databaseUrl(), max: 1 });
  try {
    await assertDisposableDatabase(admin);
    const c = await admin.connect();
    try {
      if (opts.reset ?? true) {
        await c.query("drop schema if exists public cascade");
        await c.query("create schema public authorization pg_database_owner");
        await c.query("grant usage on schema public to public");
      }
      await bootstrapRoles(c);
      await setTestRolePasswords(c);
    } finally {
      c.release();
    }
  } finally {
    await admin.end();
  }
  const migrator = new Pool({ connectionString: roleUrl(ROLES.migrator), max: 1 });
  try {
    const c = await migrator.connect();
    try {
      return await migrate(c);
    } finally {
      c.release();
    }
  } finally {
    await migrator.end();
  }
}

export interface FixtureTenant {
  tenantId: string;
  workspaceId: string;
  /** The owner made by createPersonalTenant. */
  owner: string;
  /** A second active member with tenant role `member`. */
  member: string;
  idpSubject: string;
  devices: { owner: string; member: string };
  /** Hashes written by seedTenantRows for the owner, for resolver tests. */
  seeds: { sessionTokenSha256: string; enrollmentCodeSha256: string; patTokenSha256: string };
}

export interface PgTenantFixture {
  /** DATABASE_URL's role (superuser): for assertions that must see everything. */
  admin: Pool;
  migrator: Pool;
  app: Pool;
  retention: Pool;
  jobs: Pool;
  a: FixtureTenant;
  b: FixtureTenant;
  ctx(t: FixtureTenant, memberId: string, memberScope?: MemberScope): TenantContext;
  close(): Promise<void>;
}

const hex = () => sha256Hex(randomBytes(32));

async function makeTenant(app: Pool, label: string): Promise<FixtureTenant> {
  const idpSubject = `oidc|fixture-${label}-${uuidv7()}`;
  const t = await withTransaction(app, (tx) => createPersonalTenant(tx, { idpSubject, email: `owner-${label}@example.test` }));
  const member = uuidv7();
  const devices = { owner: uuidv7(), member: uuidv7() };
  const ctx: TenantContext = { tenantId: t.tenantId, principalId: t.memberId, memberId: t.memberId, tenantRole: "owner" };
  await withTenant(app, ctx, async (tx) => {
    const email = `member-${label}@example.test`;
    await tx.query(
      "insert into members (tenant_id, id, email, email_hash, tenant_role, state) values ($1, $2, $3, $4, 'member', 'active')",
      [t.tenantId, member, email, sha256Hex(email)],
    );
    await tx.query("insert into workspace_members (tenant_id, workspace_id, member_id, workspace_role) values ($1, $2, $3, 'member')", [t.tenantId, t.workspaceId, member]);
    for (const [who, id] of [[t.memberId, devices.owner], [member, devices.member]] as const) {
      await tx.query(
        "insert into devices (tenant_id, id, member_id, public_jwk, key_storage, name) values ($1, $2, $3, $4, 'secure_enclave', 'Test Mac')",
        [t.tenantId, id, who, JSON.stringify({ kty: "EC", crv: "P-256", x: hex(), y: hex() })],
      );
    }
  });
  return {
    tenantId: t.tenantId, workspaceId: t.workspaceId, owner: t.memberId, member, idpSubject, devices,
    seeds: { sessionTokenSha256: "", enrollmentCodeSha256: "", patTokenSha256: "" },
  };
}

/** Two personal tenants with two active members and one device each, on a freshly migrated database. */
export async function pgTenantFixture(opts: { appPoolSize?: number } = {}): Promise<PgTenantFixture> {
  installNetworkGuard();
  await freshDatabase();
  const admin = new Pool({ connectionString: databaseUrl(), max: 2 });
  const migrator = new Pool({ connectionString: roleUrl(ROLES.migrator), max: 2 });
  const app = new Pool({ connectionString: roleUrl(ROLES.app), max: opts.appPoolSize ?? 4 });
  const retention = new Pool({ connectionString: roleUrl(ROLES.retention), max: 2 });
  const jobs = new Pool({ connectionString: roleUrl(ROLES.jobs), max: 2 });
  const endAll = () => Promise.allSettled([admin.end(), migrator.end(), app.end(), retention.end(), jobs.end()]);
  let a: FixtureTenant, b: FixtureTenant;
  try {
    a = await makeTenant(app, "a");
    b = await makeTenant(app, "b");
  } catch (e) {
    await endAll(); // a failed setup must not leave pools open (the test process would hang) and still reports `e`
    throw e;
  }
  return {
    admin, migrator, app, retention, jobs, a, b,
    ctx: (t, memberId, memberScope) => ({
      tenantId: t.tenantId, principalId: memberId, memberId, tenantRole: memberId === t.owner ? "owner" : "member",
      ...(memberScope ? { memberScope } : {}),
    }),
    close: async () => {
      await Promise.all([admin.end(), migrator.end(), app.end(), retention.end(), jobs.end()]);
    },
  };
}

async function seedMember(tx: Tx, t: FixtureTenant, memberId: string, deviceId: string): Promise<FixtureTenant["seeds"]> {
  const seeds = { sessionTokenSha256: hex(), enrollmentCodeSha256: hex(), patTokenSha256: hex() };
  const q = (sql: string, params: unknown[]) => tx.query(sql, params);
  await q("insert into sessions (tenant_id, id, member_id, token_sha256, csrf_sha256, expires_at) values ($1, $2, $3, $4, $5, now() + interval '12 hours')",
    [t.tenantId, uuidv7(), memberId, seeds.sessionTokenSha256, hex()]);
  await q("insert into device_nonces (tenant_id, device_id, nonce, audience) values ($1, $2, $3, 'device')", [t.tenantId, deviceId, hex().slice(0, 32)]);
  await q("insert into device_enrollment_codes (tenant_id, code_sha256, member_id, code_challenge, redirect_uri) values ($1, $2, $3, $4, 'offload://enroll')",
    [t.tenantId, seeds.enrollmentCodeSha256, memberId, hex()]);
  await q("insert into personal_access_tokens (tenant_id, id, member_id, name, scopes, token_sha256) values ($1, $2, $3, 'mcp', '{mcp}', $4)",
    [t.tenantId, uuidv7(), memberId, seeds.patTokenSha256]);
  await q("insert into pseudonym_key_wraps (tenant_id, device_id, wrapped_key, method) values ($1, $2, $3, 'device')", [t.tenantId, deviceId, hex()]);
  await q("insert into idempotency_keys (tenant_id, key, request_sha256, status, response) values ($1, $2, $3, 201, '{}')", [t.tenantId, `idem-${uuidv7()}`, hex()]);
  await q("insert into exclusions (tenant_id, member_id, id, kind, value, source) values ($1, $2, $3, 'host', 'bank.example.test', 'user')", [t.tenantId, memberId, uuidv7()]);
  await q("insert into consents (tenant_id, id, member_id, device_id, notice_id, notice_version) values ($1, $2, $3, $4, 'what-leaves-your-mac', '1')", [t.tenantId, uuidv7(), memberId, deviceId]);
  const importId = uuidv7();
  await q("insert into imports (tenant_id, member_id, id, source_kind, first_day, last_day) values ($1, $2, $3, 'screenshots', '2026-11-01', '2026-11-02')", [t.tenantId, memberId, importId]);
  await q("insert into ingest_batches (tenant_id, device_id, seq, kind, body_sha256, object_count) values ($1, $2, 1, 'observations', $3, 2)", [t.tenantId, deviceId, hex()]);
  for (const day of ["2026-11-13", "2026-11-14"]) {
    await q(`insert into observations (tenant_id, device_id, object_id, day, member_id, ts, kind, app_bundle_id, source)
             values ($1, $2, $3, $4::date, $5, ($4::date + time '09:00') at time zone 'UTC', 'focus', 'com.example.app', 'live')`,
      [t.tenantId, deviceId, ulid(), day, memberId]);
    await q(`insert into observation_texts (tenant_id, device_id, object_id, day, member_id, ts, text, text_hash, text_source)
             values ($1, $2, $3, $4::date, $5, ($4::date + time '09:00') at time zone 'UTC', 'Invoice <doc:h_0123456789abcdef>', $6, 'ax')`,
      [t.tenantId, deviceId, ulid(), day, memberId, hex()]);
  }
  const purgeRequestId = uuidv7();
  await q("insert into purge_requests (tenant_id, id, member_id, scope, scope_ref, requested_by) values ($1, $2, $3, 'import', $4, $3)", [t.tenantId, purgeRequestId, memberId, importId]);
  await q("insert into purge_log (tenant_id, id, purge_request_id, scope, scope_ref, rows_deleted, requested_by) values ($1, $2, $3, 'import', $4, '{\"observations\": 0}', $5)",
    [t.tenantId, uuidv7(), purgeRequestId, importId, memberId]);
  const eventId = uuidv7();
  await q("insert into events_outbox (tenant_id, id, type, payload) values ($1, $2, 'import.wiped', $3)", [t.tenantId, eventId, JSON.stringify({ import_id: importId })]);
  await q("insert into outbox_deliveries (tenant_id, event_id, consumer, attempts) values ($1, $2, 'webhook:fixture', 0)", [t.tenantId, eventId]);
  return seeds;
}

/**
 * One row or more in every tenant table for both members of both tenants, written as offload_app through withTenant
 * (so the WITH CHECK side of every policy runs). Records the owner's hashes in `t.seeds`.
 */
export async function seedTenantRows(fx: PgTenantFixture): Promise<void> {
  for (const t of [fx.a, fx.b]) {
    for (const [memberId, deviceId] of [[t.owner, t.devices.owner], [t.member, t.devices.member]] as const) {
      const seeds = await withTenant(fx.app, fx.ctx(t, memberId), (tx) => seedMember(tx, t, memberId, deviceId));
      if (memberId === t.owner) t.seeds = seeds;
    }
    await withTenant(fx.app, fx.ctx(t, t.owner), async (tx) => {
      const head = (await tx.query("select seq, hash from audit_events order by seq desc limit 1")).rows[0];
      await tx.query("insert into audit_anchors (tenant_id, seq, head_hash, signature, key_id) values ($1, $2, $3, $4, 'fixture-key')",
        [t.tenantId, head.seq, head.hash, hex()]);
    });
  }
  await fx.app.query("insert into magic_links (token_sha256, email_hash, return_to) values ($1, $2, '/')", [hex(), hex()]);
}

/** Fault injection: `hook` runs inside every transaction right before COMMIT; throw from it to force a rollback.
 * Returns the remover. */
export function onBeforeCommit(hook: (tx: Tx) => void | Promise<void>): () => void {
  return registerBeforeCommit(hook);
}

/**
 * Refuses unless the database is disposable: its name ends in `test` (`offload_test` in CI), or an administrator
 * marked it with `comment on database <name> is 'offload:disposable'`. freshDatabase drops schema public.
 */
export async function assertDisposableDatabase(admin: Pool): Promise<void> {
  const r = (await admin.query(
    "select current_database() as name, shobj_description(oid, 'pg_database') as note from pg_database where datname = current_database()",
  )).rows[0] as { name: string; note: string | null };
  if (/(^|_)test$/.test(r.name) || r.note === "offload:disposable") return;
  throw new Error("refusing to reset a database that is not disposable: name it *_test or comment it 'offload:disposable'");
}
