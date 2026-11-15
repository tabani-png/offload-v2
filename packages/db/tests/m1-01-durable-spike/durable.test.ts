import { afterAll, beforeAll, expect, test } from "bun:test";
import { createHash, randomUUID } from "node:crypto";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { Pool } from "pg";
import { MAX_RECV_MS, DurableRuntime, assertIdsOnly, type WorkflowFn } from "../../src/durable/index.ts";
import { testRolePassword } from "@offload/testkit";
import { TENANT_A, TENANT_B, bump, count, databaseUrl, fakeClock, newPool, waitFor, withUser } from "./helpers.ts";

const CANARY = "Quarterly invoice for Hartwell Bakery, total 4,812 pounds";
const canaryHash = createHash("sha256").update(CANARY).digest("hex");
const seen: Record<string, string[]> = {};
const note = (k: string, v: string) => void (seen[k] ??= []).push(v);
const dir = mkdtempSync(join(tmpdir(), "durable-"));
const clock = fakeClock(Date.UTC(2030, 0, 1, 0, 0, 0));

const workflows: Record<string, WorkflowFn> = {
  "tenant-probe": async (rt, input) => {
    const got = await rt.step("read-tenant", () =>
      rt.withTenant(async (c) => (await c.query("select current_setting('app.tenant_id') as t")).rows[0].t as string),
    );
    note(`tenant:${String(input["tenant_id"])}`, got);
  },
  "ids-only": async (rt) => {
    // The step reads content, but only an id/hash may leave it.
    await rt.step("hash-content", async () => canaryHash);
  },
  "leaky": async (rt) => {
    await rt.step("leak-content", async () => CANARY);
  },
  "waiter-msg": async (rt) => {
    await rt.step("wait-start", async () => void bump(join(dir, "waiter-msg.count")));
    await rt.recv("approval", 30_000);
  },
  "sleeper": async (rt) => {
    await rt.step("before", async () => void bump(join(dir, "sleeper-before.count")));
    await rt.sleep(1_500);
    await rt.step("after", async () => void bump(join(dir, "sleeper-after.count")));
  },
  "tick-wf": async (rt) => {
    await rt.step("tick", async () => void bump(join(dir, "tick.count")));
  },
  "waiter": async (rt) => {
    await rt.step("wait-start", async () => void bump(join(dir, "waiter.count")));
    await rt.recv("approval", 30_000);
  },
};

let rt: DurableRuntime;
let pool: Pool;
let migratorOwned = false;

beforeAll(async () => {
  pool = newPool();
  await pool.query("drop schema if exists durable cascade");
  let migratorUrl: string | undefined;
  try {
    await pool.query("do $$ begin if not exists (select 1 from pg_roles where rolname = 'offload_migrator') then create role offload_migrator login; end if; end $$");
    await pool.query("select format('grant create on database %I to offload_migrator', current_database()) as q").then((r) => pool.query(r.rows[0].q));
    // The same test-only password the testkit fixture uses (never printed): a random one here would break a
    // concurrent fixture run on a password-auth cluster, since roles are cluster-wide.
    const password = testRolePassword("offload_migrator");
    await pool.query(`alter role offload_migrator login password '${password}'`);
    migratorUrl = withUser(databaseUrl(), "offload_migrator", password);
    migratorOwned = true;
  } catch {
    migratorUrl = undefined; // no CREATE ROLE privilege: the ownership assertion is skipped below
  }
  rt = await DurableRuntime.create({
    databaseUrl: databaseUrl(),
    ...(migratorUrl ? { migratorUrl } : {}),
    clock,
    workflows,
  });
});

afterAll(async () => {
  await rt?.shutdown();
  await pool?.end();
});

async function stateOf(id: string): Promise<string | undefined> {
  return (await rt.list({})).find((w) => w.workflowId === id)?.state;
}

async function durableDump(): Promise<string> {
  const tables = (await pool.query("select tablename from pg_tables where schemaname = 'durable' order by 1")).rows;
  let out = "";
  for (const t of tables) out += (await pool.query(`select x::text as r from durable."${t.tablename}" x`)).rows.map((r) => r.r).join("\n");
  return out;
}

// ---- kill scenario (child Bun process), run once and shared by the first two tests ----
let scenario: Promise<{ workflowId: string; checkpointBeforeKill: boolean; killedExit: number; killedAlive: boolean }> | undefined;
const alive = (pid: number) => {
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
};
function killScenario() {
  scenario ??= (async () => {
    const wd = mkdtempSync(join(tmpdir(), "durable-kill-"));
    const workflowId = randomUUID();
    const script = join(import.meta.dir, "child-workflow.ts");
    const env = { ...process.env };
    // process.execPath, not "bun": on PATH `bun` can be a shell shim, and SIGKILL would then miss the workflow process.
    const first = Bun.spawn([process.execPath, script, "start", wd, workflowId], { env, stdout: "ignore", stderr: "ignore" });
    const checkpointed = async () =>
      (await pool.query("select 1 from durable.operation_outputs where workflow_uuid = $1 and function_name = 'step-one'", [workflowId])).rowCount === 1;
    await waitFor("step one checkpoint row", async () => (await checkpointed()) || null);
      first.kill("SIGKILL");
    const killedExit = await first.exited;
    const killedAlive = alive(Number(await Bun.file(join(wd, "start.pid")).text()));
    await Bun.write(join(wd, "release"), "go");
    const second = Bun.spawn([process.execPath, script, "resume", wd, workflowId], { env, stdout: "ignore", stderr: "ignore" });
    expect(await second.exited).toBe(0);
    scenarioDir = wd;
    return { workflowId, checkpointBeforeKill: true, killedExit, killedAlive };
  })();
  return scenario;
}
let scenarioDir = "";

test("DURABLE: a two-step workflow killed between steps resumes once on Bun", async () => {
  const s = await killScenario();
  expect(s.checkpointBeforeKill).toBe(true);
  expect(s.killedExit).not.toBe(0); // it really was killed
  expect(s.killedAlive).toBe(false); // the workflow process itself, not only a launcher in front of it
  expect(count(join(scenarioDir, "step1.count"))).toBe(1);
  expect(count(join(scenarioDir, "step2.count"))).toBe(1);
  expect(await stateOf(s.workflowId)).toBe("success");
});

test("DURABLE: a completed step is not re-run after restart", async () => {
  await killScenario();
  expect(count(join(scenarioDir, "step1.count"))).toBe(1);
});

test("DURABLE: workflow input carries tenant_id and steps run inside withTenant", async () => {
  await expect(rt.startWorkflow("tenant-probe", {} as never)).rejects.toThrow(/tenant_id/);
  await expect(rt.startWorkflow("tenant-probe", { tenant_id: "" })).rejects.toThrow(/tenant_id/);
  const { workflowId } = await rt.startWorkflow("tenant-probe", { tenant_id: TENANT_A });
  await waitFor("tenant-probe success", async () => (await stateOf(workflowId)) === "success" || null);
  expect(seen[`tenant:${TENANT_A}`]).toEqual([TENANT_A]);
});

test("DURABLE: workflow inputs and messages hold ids only", async () => {
  expect(() => assertIdsOnly({ tenant_id: TENANT_A, x: "a".repeat(65) })).toThrow();
  expect(() => assertIdsOnly({ tenant_id: TENANT_A, x: "two words" })).toThrow();
  expect(() => assertIdsOnly({ tenant_id: TENANT_A, run_id: randomUUID(), hash: canaryHash, kind: "approve" })).not.toThrow();
  await expect(rt.startWorkflow("ids-only", { tenant_id: TENANT_A, title: CANARY })).rejects.toThrow();
  await expect(rt.startWorkflow("ids-only", { tenant_id: TENANT_A, [CANARY]: true })).rejects.toThrow(/key|whitespace|64/);
  const live = await rt.startWorkflow("waiter-msg", { tenant_id: TENANT_A });
  await waitFor("waiter-msg started", async () => count(join(dir, "waiter-msg.count")) === 1 || null);
  await expect(rt.send(live.workflowId, "approval", { note: CANARY })).rejects.toThrow(/whitespace|64/);
  await rt.cancel(live.workflowId);
  const ok = await rt.startWorkflow("ids-only", { tenant_id: TENANT_A });
  await waitFor("ids-only success", async () => (await stateOf(ok.workflowId)) === "success" || null);
  // A step that returns content fails instead of writing it into schema durable.
  const bad = await rt.startWorkflow("leaky", { tenant_id: TENANT_A });
  await waitFor("leaky error", async () => (await stateOf(bad.workflowId)) === "error" || null);
  const dump = await durableDump();
  expect(dump).toContain(canaryHash);
  expect(dump).not.toContain("Hartwell");
  expect(dump).not.toContain("invoice");
});

test("DURABLE: recv longer than 15 minutes is refused", async () => {
  expect(MAX_RECV_MS).toBe(900_000);
  await expect(rt.recv("approval", 900_001)).rejects.toThrow(/900000|15 minutes/);
  // Exactly at the limit passes the length check (it fails for another reason: there is no workflow here).
  const atLimit = await rt.recv("approval", MAX_RECV_MS).then(() => "", (e: Error) => e.message);
  expect(atLimit).not.toMatch(/15 minutes/);
});

test("DURABLE: a scheduled workflow fires on its cron in a fake clock", async () => {
  await rt.schedule("*/5 * * * *", "tick-wf");
  const fired = () => rt.list({ name: "tick-wf" }).then((l) => l.length);
  await new Promise((r) => setTimeout(r, 300));
  expect(await fired()).toBe(0); // the fake clock has not moved
  clock.advance(5 * 60_000);
  await waitFor("first tick", async () => (await fired()) >= 1 || null);
  await new Promise((r) => setTimeout(r, 400));
  expect(await fired()).toBe(1); // exactly once for that tick
  clock.advance(5 * 60_000);
  await waitFor("second tick", async () => (await fired()) >= 2 || null);
  await new Promise((r) => setTimeout(r, 400));
  expect(await fired()).toBe(2);
  await expect(rt.schedule("not a cron", "tick-wf")).rejects.toThrow();
});

test("DURABLE: cancel stops a sleeping workflow before its next step", async () => {
  const { workflowId } = await rt.startWorkflow("sleeper", { tenant_id: TENANT_A });
  await waitFor("sleeper before-step", async () => count(join(dir, "sleeper-before.count")) === 1 || null);
  await rt.cancel(workflowId);
  await waitFor("sleeper cancelled", async () => (await stateOf(workflowId)) === "cancelled" || null);
  await new Promise((r) => setTimeout(r, 2_500)); // well past the 1.5 s sleep
  expect(count(join(dir, "sleeper-after.count"))).toBe(0);
  expect((await rt.list({ name: "sleeper", state: "cancelled" })).map((w) => w.workflowId)).toContain(workflowId);
});

test("DURABLE: purgeTenant removes every durable row of that tenant and no other", async () => {
  const a = await rt.startWorkflow("waiter", { tenant_id: TENANT_A });
  const b = await rt.startWorkflow("waiter", { tenant_id: TENANT_B });
  await waitFor("both waiters started", async () => count(join(dir, "waiter.count")) >= 2 || null);
  await rt.send(a.workflowId, "approval", { tenant_id: TENANT_A, decision: "approve" });
  await rt.send(b.workflowId, "approval", { tenant_id: TENANT_B, decision: "approve" });
  await waitFor("waiters done", async () => (await stateOf(a.workflowId)) === "success" && (await stateOf(b.workflowId)) === "success" || null);
  const rowsFor = async (id: string) =>
    Number(
      (
        await pool.query(
          `select (select count(*) from durable.workflow_status where workflow_uuid = $1)
                + (select count(*) from durable.operation_outputs where workflow_uuid = $1)
                + (select count(*) from durable.workflow_input where workflow_uuid = $1)
                + (select count(*) from durable.workflow_output where workflow_uuid = $1)
                + (select count(*) from durable.notifications where destination_uuid = $1) as n`,
          [id],
        )
      ).rows[0].n,
    );
  expect(await rowsFor(a.workflowId)).toBeGreaterThan(0);
  expect(await rowsFor(b.workflowId)).toBeGreaterThan(0);
  const aBefore = (await rt.list({})).filter((w) => w.tenantId === TENANT_A).length;
  const res = await rt.purgeTenant(TENANT_A);
  expect(res.workflowsDeleted).toBe(aBefore);
  expect(res.workflowsDeleted).toBeGreaterThanOrEqual(1);
  expect(await rowsFor(a.workflowId)).toBe(0);
  expect(await rowsFor(b.workflowId)).toBeGreaterThan(0);
  expect((await rt.list({})).filter((w) => w.tenantId === TENANT_A)).toHaveLength(0);
  expect((await rt.list({})).filter((w) => w.tenantId === TENANT_B).length).toBeGreaterThan(0);
});

test("DURABLE: schema durable is owned by offload_migrator", async () => {
  if (!migratorOwned) return; // role creation not permitted in this database
  const r = await pool.query("select pg_get_userbyid(nspowner) as owner from pg_namespace where nspname = 'durable'");
  expect(r.rows[0].owner).toBe("offload_migrator");
});
