// Real Postgres 17 for the p43b tests. The CI database is shared by every package's tests, so each test file creates
// its own uniquely named schema and app role, applies services/brain/sql into it and drops both afterwards.
import { SQL } from "bun";
import { randomBytes, randomUUID } from "node:crypto";
import type { WeekTask } from "../../src/records/week-record.ts";
import { runMemberUpdate, type MemberUpdateInput } from "../../src/store/job.ts";
import { applyUserModelMigrations } from "../../src/store/migrate.ts";
import { bunRunInTenant, type RunInTenant, type TenantContext } from "../../src/store/tenant.ts";
import { fixtureWeek, mondayNoonAfter, MONDAYS, SEED } from "../fixtures/window.ts";

export const HAS_DB = (process.env["DATABASE_URL"] ?? "") !== "";

export interface TestDb {
  sql: SQL;
  schema: string;
  role: string;
  run: RunInTenant;
  /** Tenant A has members A1 and A2; tenant B has member B1. */
  A1: TenantContext;
  A2: TenantContext;
  B1: TenantContext;
  workspaceA: string;
  workspaceB: string;
  cleanup: () => Promise<void>;
}

const member = (tenantId: string): TenantContext => {
  const id = randomUUID();
  return { tenantId, memberId: id, principalId: id, tenantRole: "owner" };
};

export async function testDb(label: string): Promise<TestDb> {
  const sql = new SQL(process.env["DATABASE_URL"]!, { max: 4 });
  const suffix = randomBytes(5).toString("hex");
  const schema = `p43b_${label}_${suffix}`;
  const role = `p43b_app_${suffix}`;
  await sql.unsafe(`CREATE ROLE ${role} NOLOGIN NOBYPASSRLS`);
  const drop = async () => {
    await sql.unsafe(`DROP SCHEMA IF EXISTS ${schema} CASCADE`);
    await sql.unsafe(`DROP OWNED BY ${role}; DROP ROLE IF EXISTS ${role}`);
    await sql.close();
  };
  try {
    await sql.unsafe(`CREATE SCHEMA ${schema}; GRANT USAGE ON SCHEMA ${schema} TO ${role}`);
    await applyUserModelMigrations(sql, { schema, appRole: role });
  } catch (err) {
    await drop();
    throw err;
  }
  const tenantA = randomUUID();
  const tenantB = randomUUID();
  return {
    sql, schema, role, run: bunRunInTenant(sql, { schema, appRole: role }),
    A1: member(tenantA), A2: member(tenantA), B1: member(tenantB), workspaceA: randomUUID(), workspaceB: randomUUID(),
    cleanup: drop,
  };
}

/** Fix rules stand-in: half of the task's weekly hours, 3 setup hours. */
export const estimateFor: NonNullable<MemberUpdateInput["estimateFor"]> = (t: WeekTask) =>
  t.minutes.value <= 0 ? null : { fixKind: "agent_workflow", weeklyHoursSaved: Math.round((t.minutes.value / 60) * 50) / 100, setupHours: 3, ruleConfidence: 0.7, workKind: "email" };

/** Four fixture weeks for one member (week 3 without calls), each run by the job the Monday after. */
export async function seedFourWeeks(db: TestDb, ctx: TenantContext, workspaceId: string, seedOffset = 0): Promise<number> {
  let now = 0;
  for (const [i, monday] of MONDAYS.entries()) {
    const fx = fixtureWeek(monday, { seed: SEED + seedOffset + i, ...(i === 2 ? { without: ["calls"] } : {}) });
    now = mondayNoonAfter(monday);
    const at = now;
    await db.run(ctx, (tx) => runMemberUpdate(tx, { window: fx.window, now: at, workspaceId, estimateFor }));
  }
  return now;
}

/** Every row of every user-model table as JSON text, read as the superuser (no RLS). */
export async function dumpAll(db: TestDb, tables: readonly string[]): Promise<Record<string, unknown[]>> {
  const out: Record<string, unknown[]> = {};
  for (const t of tables) out[t] = [...(await db.sql.unsafe(`SELECT to_jsonb(x) AS row FROM ${db.schema}.${t} x ORDER BY 1`))].map((r) => (r as { row: unknown }).row);
  return out;
}
