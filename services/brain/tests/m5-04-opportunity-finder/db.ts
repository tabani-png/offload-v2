// Real Postgres for the PERSIST tests: the brain's tables in their own schema and app role, as p43b does.
import { SQL } from "bun";
import { randomBytes, randomUUID } from "node:crypto";
import { applyUserModelMigrations } from "../../src/store/migrate.ts";
import { bunRunInTenant, type RunInTenant, type TenantContext } from "../../src/store/tenant.ts";

export const HAS_DB = (process.env["DATABASE_URL"] ?? "") !== "";

export interface TestDb {
  sql: SQL;
  schema: string;
  run: RunInTenant;
  A1: TenantContext;
  A2: TenantContext;
  workspace: string;
  cleanup: () => Promise<void>;
}

const member = (tenantId: string): TenantContext => {
  const id = randomUUID();
  return { tenantId, memberId: id, principalId: id, tenantRole: "owner" };
};

export async function testDb(): Promise<TestDb> {
  const sql = new SQL(process.env["DATABASE_URL"]!, { max: 4 });
  const suffix = randomBytes(5).toString("hex");
  const schema = `m504_${suffix}`;
  const role = `m504_app_${suffix}`;
  await sql.unsafe(`CREATE ROLE ${role} NOLOGIN NOBYPASSRLS`);
  await sql.unsafe(`CREATE SCHEMA ${schema}; GRANT USAGE ON SCHEMA ${schema} TO ${role}`);
  await applyUserModelMigrations(sql, { schema, appRole: role });
  const tenant = randomUUID();
  return {
    sql, schema, run: bunRunInTenant(sql, { schema, appRole: role }), A1: member(tenant), A2: member(tenant), workspace: randomUUID(),
    cleanup: async () => {
      await sql.unsafe(`DROP SCHEMA IF EXISTS ${schema} CASCADE`);
      await sql.unsafe(`DROP OWNED BY ${role}; DROP ROLE IF EXISTS ${role}`);
      await sql.close();
    },
  };
}

/** Rows of `tables` for one member as JSON, read as the superuser. */
export async function dump(db: TestDb, memberId: string, tables: readonly string[]): Promise<Record<string, unknown[]>> {
  const out: Record<string, unknown[]> = {};
  for (const t of tables) out[t] = [...(await db.sql.unsafe(`SELECT to_jsonb(x) AS row FROM ${db.schema}.${t} x WHERE member_id = $1 ORDER BY 1`, [memberId]))].map((r) => (r as { row: unknown }).row);
  return out;
}
