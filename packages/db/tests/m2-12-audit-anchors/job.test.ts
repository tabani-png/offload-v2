import { afterAll, beforeAll, expect, test } from "bun:test";
import { Pool } from "pg";
import { pgTenantFixture, roleUrl, type PgTenantFixture } from "@offload/testkit";
import { fakeSigner } from "@offload/testkit/src/audit/index.ts";
import {
  AUDIT_ANCHOR_CRON, DurableRuntime, ROLES, assertIdsOnly, auditAnchorWorkflows, appendAudit, withTenant, type TenantContext,
} from "../../src/index.ts";

let fx: PgTenantFixture;
let rt: DurableRuntime;
let now = Date.UTC(2030, 0, 1, 0, 30, 0);
const clock = { now: () => now };
const signer = fakeSigner();

beforeAll(async () => {
  fx = await pgTenantFixture({ appPoolSize: 6 });
  // The durable schema is outside the public reset: start it clean so the dump below sees only this suite.
  await fx.admin.query("drop schema if exists durable cascade");
  await fx.admin.query("select format('grant create on database %I to offload_migrator', current_database()) as q").then((r) => fx.admin.query(r.rows[0].q));
  rt = await DurableRuntime.create({
    databaseUrl: roleUrl(ROLES.app),
    migratorUrl: roleUrl(ROLES.migrator),
    clock,
    workflows: auditAnchorWorkflows({ appPool: fx.app, jobsPool: fx.jobs, signer, clock: { now: () => new Date(now) } }),
  });
});
afterAll(async () => {
  await rt?.shutdown();
  await fx?.close();
});

const count = async (tenantId: string) => Number((await fx.admin.query("select count(*) as n from audit_anchors where tenant_id = $1", [tenantId])).rows[0].n);
const settle = (ms: number) => new Promise((r) => setTimeout(r, ms));
async function waitFor(what: string, probe: () => Promise<boolean>, timeoutMs = 20_000): Promise<void> {
  const end = Date.now() + timeoutMs;
  while (!(await probe())) {
    if (Date.now() > end) throw new Error(`timed out waiting for ${what}`);
    await settle(40);
  }
}
const grow = (ctx: TenantContext) => withTenant(fx.app, ctx, (tx) =>
  appendAudit(tx, { principalId: ctx.principalId, action: "batch.committed", subjectType: "batch", subjectId: "b-1", details: {} }));

test("ANCHOR: the hourly job anchors every tenant once per hour in a fake clock", async () => {
  expect(AUDIT_ANCHOR_CRON).toBe("0 * * * *");
  const a: TenantContext = fx.ctx(fx.a, fx.a.owner);
  const b: TenantContext = fx.ctx(fx.b, fx.b.owner);
  await rt.schedule(AUDIT_ANCHOR_CRON, "auditAnchor");
  await settle(300);
  expect([await count(fx.a.tenantId), await count(fx.b.tenantId)]).toEqual([0, 0]); // the clock has not reached the hour

  now = Date.UTC(2030, 0, 1, 1, 0, 0);
  await waitFor("first tick", async () => (await count(fx.a.tenantId)) === 1 && (await count(fx.b.tenantId)) === 1);
  await settle(400);
  expect([await count(fx.a.tenantId), await count(fx.b.tenantId)]).toEqual([1, 1]); // once per hour, not once per poll

  await grow(a);
  await grow(b);
  now = Date.UTC(2030, 0, 1, 2, 0, 0);
  await waitFor("second tick", async () => (await count(fx.a.tenantId)) === 2 && (await count(fx.b.tenantId)) === 2);
  await settle(400);
  expect([await count(fx.a.tenantId), await count(fx.b.tenantId)]).toEqual([2, 2]);
  const signed = (await fx.admin.query("select signed_at from audit_anchors where tenant_id = $1 order by seq", [fx.a.tenantId])).rows;
  expect(signed.map((r) => (r.signed_at as Date).toISOString())).toEqual(["2030-01-01T01:00:00.000Z", "2030-01-01T02:00:00.000Z"]);
});

test("ANCHOR: the anchor job's workflow input and step outputs hold ids only", async () => {
  const pool = new Pool({ connectionString: process.env["DATABASE_URL"]!, max: 1 });
  try {
    const inputs = (await pool.query("select inputs from durable.workflow_status where name = 'auditAnchor'")).rows;
    expect(inputs.length).toBeGreaterThanOrEqual(2);
    for (const r of inputs) {
      const input = JSON.parse(r.inputs);
      const first = Array.isArray(input) ? input[0] : input.args?.[0] ?? input;
      expect(Object.keys(first).sort()).toEqual(["scheduled_for", "tenant_id"]);
      assertIdsOnly(first);
    }
    const outs = (await pool.query("select function_name, output from durable.operation_outputs where output is not null")).rows;
    expect(outs.length).toBeGreaterThan(0);
    const sigs = (await fx.admin.query("select signature from audit_anchors")).rows.map((r) => r.signature as string);
    for (const o of outs) {
      assertIdsOnly(JSON.parse(o.output), `step ${o.function_name}`);
      for (const s of sigs) expect(o.output).not.toContain(s);
    }
    const dump = (await pool.query("select x::text as r from durable.workflow_status x")).rows.map((r) => r.r).join("\n")
      + outs.map((o) => o.output).join("\n");
    for (const s of sigs) expect(dump).not.toContain(s);
  } finally {
    await pool.end();
  }
});
