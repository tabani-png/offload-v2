// Real Postgres for the CONSUME tests: the capture tables from packages/db (pgTenantFixture resets schema public of
// the disposable test database) and the brain's user-model tables in their own schema and app role, as p43b does.
import { SQL } from "bun";
import { randomBytes } from "node:crypto";
import { uuidv7, withTenant, type TenantContext } from "@offload/db";
import { pgTenantFixture, type FixtureTenant, type PgTenantFixture } from "@offload/testkit";
import { pgCaptureStore } from "../../src/understanding/capture.ts";
import type { IngestedEvent } from "../../src/understanding/capture.ts";
import type { UnderstandingDeps } from "../../src/understanding/job.ts";
import { applyUserModelMigrations } from "../../src/store/migrate.ts";
import { bunRunInTenant, type RunInTenant } from "../../src/store/tenant.ts";
import type { Built } from "./fixtures.ts";

export const HAS_DB = (process.env["DATABASE_URL"] ?? "") !== "";

export const BRAIN_TABLES = ["task_ledger", "episodes", "propositions", "day_records", "week_records", "month_records", "quarter_records", "figure_index", "opportunities"] as const;

export interface ConsumeDb {
  fx: PgTenantFixture;
  sql: SQL;
  schema: string;
  role: string;
  /** Counts every brain transaction, to prove a duplicate event writes nothing. */
  brainCalls: { n: number };
  deps: UnderstandingDeps;
  close(): Promise<void>;
}

export async function consumeDb(): Promise<ConsumeDb> {
  const fx = await pgTenantFixture();
  const sql = new SQL(process.env["DATABASE_URL"]!, { max: 4 });
  const suffix = randomBytes(5).toString("hex");
  const schema = `m501_${suffix}`;
  const role = `m501_app_${suffix}`;
  await sql.unsafe(`CREATE ROLE ${role} NOLOGIN NOBYPASSRLS`);
  await sql.unsafe(`CREATE SCHEMA ${schema}; GRANT USAGE ON SCHEMA ${schema} TO ${role}`);
  await applyUserModelMigrations(sql, { schema, appRole: role });
  const inner = bunRunInTenant(sql, { schema, appRole: role });
  const brainCalls = { n: 0 };
  const runBrain: RunInTenant = (ctx, fn) => {
    brainCalls.n++;
    return inner(ctx, fn);
  };
  return {
    fx, sql, schema, role, brainCalls,
    deps: { capture: pgCaptureStore(fx.app), runBrain, clock: () => Date.now() },
    close: async () => {
      await sql.unsafe(`DROP SCHEMA IF EXISTS ${schema} CASCADE`);
      await sql.unsafe(`DROP OWNED BY ${role}; DROP ROLE IF EXISTS ${role}`);
      await sql.close();
      await fx.close();
    },
  };
}

export const todayUtc = (): string => new Date().toISOString().slice(0, 10);
export const daysAgo = (n: number): string => new Date(Date.parse(`${todayUtc()}T00:00:00Z`) - n * 86_400_000).toISOString().slice(0, 10);

const ctxOf = (db: ConsumeDb, t: FixtureTenant, memberId: string): TenantContext => db.fx.ctx(t, memberId);

/** Writes observations and texts as offload_app, like ingest does, with partition `day` = `day` (imports: the ingest date). */
export async function insertCapture(db: ConsumeDb, t: FixtureTenant, memberId: string, deviceId: string, built: Built, day: string): Promise<void> {
  await withTenant(db.fx.app, ctxOf(db, t, memberId), async (tx) => {
    for (const o of built.observations) {
      await tx.query(
        `insert into observations (tenant_id, device_id, object_id, day, member_id, ts, kind, app_bundle_id, app_name, title, host, doc, keys, clicks, source, import_id)
         values ($1, $2, $3, $4::date, $5, to_timestamp($6::double precision / 1000), $7, $8, $9, $10, $11, $12, $13, $14, $15, $16)`,
        [t.tenantId, deviceId, o.object_id, day, memberId, o.ts, o.kind, o.app_bundle_id, o.app_name, o.title, o.host, o.doc, o.keys, o.clicks, o.source, o.import_id],
      );
    }
    for (const x of built.texts) {
      await tx.query(
        `insert into observation_texts (tenant_id, device_id, object_id, day, member_id, ts, text, text_hash, text_source, app_bundle_id, source, import_id)
         values ($1, $2, $3, $4::date, $5, to_timestamp($6::double precision / 1000), $7, $8, $9, $10, 'import', $11)`,
        [t.tenantId, deviceId, x.object_id, day, memberId, x.ts, x.text, new Bun.CryptoHasher("sha256").update(x.text).digest("hex"), x.text_source, x.app_bundle_id, "0193a6f2-0000-7000-8000-0000000000e1"],
      );
    }
  });
}

/** The outbox event m3-01 writes for an accepted batch. */
export async function emitIngested(db: ConsumeDb, t: FixtureTenant, memberId: string, deviceId: string, seq = 1, accepted = 1): Promise<IngestedEvent> {
  const id = uuidv7();
  const payload = { device_id: deviceId, member_id: memberId, seq, accepted };
  const row = await withTenant(db.fx.app, ctxOf(db, t, memberId), async (tx) =>
    (await tx.query("insert into events_outbox (tenant_id, id, type, version, payload) values ($1, $2, 'observations.ingested', 1, $3) returning created_at", [t.tenantId, id, JSON.stringify(payload)])).rows[0],
  );
  return { tenantId: t.tenantId, eventId: id, createdAt: new Date(row.created_at).getTime(), payload };
}

/** Every brain row of a member, read as the superuser (no RLS). */
export async function brainRows(db: ConsumeDb, memberId: string): Promise<Record<string, unknown[]>> {
  const out: Record<string, unknown[]> = {};
  for (const t of BRAIN_TABLES) {
    out[t] = [...(await db.sql.unsafe(`SELECT to_jsonb(x) AS row FROM ${db.schema}.${t} x WHERE member_id = $1 ORDER BY 1`, [memberId]))].map((r) => (r as { row: unknown }).row);
  }
  return out;
}

/** Task instance episodes per task key. */
export async function instancesByKey(db: ConsumeDb, memberId: string): Promise<Map<string, number>> {
  const rows = await db.sql.unsafe(`SELECT task_key, count(*)::int AS n FROM ${db.schema}.episodes WHERE member_id = $1 AND kind = 'task_instance' GROUP BY task_key`, [memberId]);
  return new Map([...rows].map((r) => [(r as { task_key: string }).task_key, (r as { n: number }).n]));
}

/** Clears capture rows, outbox and brain rows between tests (the fixture tenants stay). */
export async function resetRows(db: ConsumeDb): Promise<void> {
  await db.fx.admin.query("delete from outbox_deliveries; delete from events_outbox; delete from observation_texts; delete from observations");
  for (const t of BRAIN_TABLES) await db.sql.unsafe(`DELETE FROM ${db.schema}.${t}`);
}
