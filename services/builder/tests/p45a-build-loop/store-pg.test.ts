// BuildStore on Postgres 17 (Bun's built-in SQL): the build lock is a partial unique index, stale builds are recovered
// in one transaction, reservations run under a row lock on the build, budget_entries are append-only and idempotent,
// deployed_at is set once, tenant RLS holds. Each run creates and drops its own schema and role (CI shares the DB).
import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { SQL } from "bun";
import { migrate, PgBuildStore } from "../../src/store-pg.ts";
import { BuildConflict, BuildEnded, HeldOutUsed, type NewBuild } from "../../src/store.ts";
import { OTHER_TENANT, T0, TENANT } from "./setup.ts";

const URL = process.env["DATABASE_URL"] ?? "";
const suffix = `${process.pid.toString(36)}${Math.random().toString(36).slice(2, 8)}`;
const SCHEMA = `p45a_${suffix}`;
const ROLE = `p45a_app_${suffix}`;
let admin: SQL;
let sql: SQL;
let store: PgBuildStore;
/** The same store connected as a non-owner role without BYPASSRLS, as offload_app will be (no DELETE granted). */
let appSql: SQL;
let app: PgBuildStore;
const TABLES = ["builds", "worker_attempts", "budget_reservations", "budget_entries", "build_receipts"];

beforeAll(async () => {
  if (URL === "") throw new Error("DATABASE_URL is required for p45a-build-loop (NEEDS_POSTGRES=1)");
  admin = new SQL({ url: URL, max: 2 });
  await admin.unsafe(`CREATE SCHEMA ${SCHEMA}`);
  sql = new SQL({ url: URL, max: 8, connection: { search_path: SCHEMA } });
  await migrate(sql);
  store = new PgBuildStore(sql);
  await admin.unsafe(`CREATE ROLE ${ROLE} NOLOGIN NOBYPASSRLS`);
  await admin.unsafe(`GRANT USAGE ON SCHEMA ${SCHEMA} TO ${ROLE}`);
  await admin.unsafe(`GRANT SELECT, INSERT, UPDATE ON ALL TABLES IN SCHEMA ${SCHEMA} TO ${ROLE}`);
  appSql = new SQL({ url: URL, max: 8, connection: { search_path: SCHEMA, role: ROLE } });
  app = new PgBuildStore(appSql);
});
afterAll(async () => {
  await appSql?.close();
  await sql?.close();
  await admin?.unsafe(`DROP SCHEMA IF EXISTS ${SCHEMA} CASCADE`);
  await admin?.unsafe(`DROP ROLE IF EXISTS ${ROLE}`);
  await admin?.close();
});

let n = 0;
const uuid = () => `0193a6f2-${(++n).toString(16).padStart(4, "0")}-7000-8000-${suffix.padEnd(12, "0").slice(0, 12).replace(/[^0-9a-f]/g, "0")}`;
/** Each build gets its own held-out hash (ADR 0029: a new build of a brief writes a new held-out check). */
const newBuild = (brief_id: string, tenant_id = TENANT): NewBuild => withHeldOut(newBuildRaw(brief_id, tenant_id));
const withHeldOut = (b: NewBuild): NewBuild => ({ ...b, bound_hashes: { ...b.bound_hashes, held_out_hash: b.id.replace(/-/g, "").padEnd(64, "c") } });
const newBuildRaw = (brief_id: string, tenant_id = TENANT): NewBuild => ({
  tenant_id,
  id: uuid(),
  fix_id: "fix_x",
  brief_id,
  cap_usd4: 40_000,
  fanout_workers: 1,
  bound_hashes: { brief_hash: "a".repeat(64), check_set_hash: "b".repeat(64), held_out_hash: "", fixture_set_hash: "d".repeat(64), cap_usd: "4.0000" },
});
const STALE = 34 * 60_000;

describe("p45a Postgres build store", () => {
  test("LOCK: (Postgres) two concurrent inserts of a live build for one brief: exactly one wins", async () => {
    const rs = await Promise.allSettled([newBuild("brief_race"), newBuild("brief_race")].map((b) => store.insertQueued(b, T0, STALE)));
    expect(rs.filter((r) => r.status === "fulfilled")).toHaveLength(1);
    const lost = rs.find((r) => r.status === "rejected") as PromiseRejectedResult;
    expect(lost.reason).toBeInstanceOf(BuildConflict);
    // another brief, or the same brief after the build ended, is free
    await store.insertQueued(newBuild("brief_other"), T0, STALE);
    const won = (rs.find((r) => r.status === "fulfilled") as PromiseFulfilledResult<{ id: string }>).value;
    await store.update(TENANT, won.id, { state: "failed", ended_at: T0 + 1 }, T0 + 1);
    await store.insertQueued(newBuild("brief_race"), T0 + 2, STALE);
  });

  test("LOCK: (Postgres) a stale build is ended infra_failed and the new build starts, once, even with two recoverers", async () => {
    const dead = await store.insertQueued(newBuild("brief_stale"), T0, STALE);
    const later = T0 + STALE + 1;
    const rs = await Promise.allSettled([newBuild("brief_stale"), newBuild("brief_stale")].map((b) => store.insertQueued(b, later, STALE)));
    expect(rs.filter((r) => r.status === "fulfilled")).toHaveLength(1);
    const old = (await store.get(TENANT, dead.id))!;
    expect(old.state).toBe("infra_failed");
    expect(old.stages.at(-1)!.note).toContain("no progress");
    // a heartbeat keeps a build live
    const live = await store.insertQueued(newBuild("brief_beat"), T0, STALE);
    await store.update(TENANT, live.id, { state: "building" }, T0 + STALE - 1000);
    await expect(store.insertQueued(newBuild("brief_beat"), T0 + STALE + 1, STALE)).rejects.toBeInstanceOf(BuildConflict);
    // the recovered build's old orchestrator can no longer write or beat
    await expect(store.update(TENANT, dead.id, { state: "ready" }, later)).rejects.toBeInstanceOf(BuildEnded);
    await expect(store.heartbeat(TENANT, dead.id, later)).rejects.toBeInstanceOf(BuildEnded);
    await store.heartbeat(TENANT, live.id, T0 + STALE);
  });

  test("CAP: (Postgres) three parallel reservations cannot exceed the remaining cap", async () => {
    const b = await store.insertQueued(newBuild("brief_cap"), T0, STALE);
    const got = await Promise.all([1, 2, 3].map((i) => store.reserve({ tenant_id: TENANT, build_id: b.id, attempt_id: `att${i}`, call_id: `attempt:att${i}`, kind: "model", usd4: 7_000, ceiling_usd4: 17_000 }, T0)));
    expect(got.filter(Boolean)).toHaveLength(2);
    // settling frees what was not spent; spend counts against the ceiling (settle one that won: the race picks which)
    const won = `attempt:att${got.indexOf(true) + 1}`;
    await store.settle({ tenant_id: TENANT, build_id: b.id, call_id: won, idempotency_key: won, scope: "build", usd4: 1_000 }, T0 + 1);
    expect(await store.reserve({ tenant_id: TENANT, build_id: b.id, attempt_id: "att4", call_id: "attempt:att4", kind: "model", usd4: 7_000, ceiling_usd4: 17_000 }, T0 + 2)).toBe(true);
    expect((await store.get(TENANT, b.id))!.spent_usd4).toBe(1_000);
  });

  test("BUDGET: (Postgres) budget_entries are append-only and idempotent by key; infra entries do not count toward the cap", async () => {
    const b = await store.insertQueued(newBuild("brief_ledger"), T0, STALE);
    const e = { tenant_id: TENANT, build_id: b.id, call_id: "c1", idempotency_key: "attempt:x", scope: "build" as const, usd4: 2_500 };
    await store.settle(e, T0);
    await store.settle(e, T0 + 1);
    await store.settle({ ...e, call_id: "c2", idempotency_key: "infra:x", scope: "infra" }, T0 + 2);
    const rows = await sql`SELECT scope, usd FROM budget_entries WHERE scope_id = ${b.id} ORDER BY at`;
    expect(rows.map((r: { scope: string; usd: string }) => [r.scope, r.usd])).toEqual([["build", "0.2500"], ["infra", "0.2500"]]);
    expect((await store.get(TENANT, b.id))!.spent_usd4).toBe(2_500);
    await expect(sql`UPDATE budget_entries SET usd = 0 WHERE scope_id = ${b.id}`).rejects.toThrow(/append-only/);
    await expect(sql`DELETE FROM budget_entries WHERE scope_id = ${b.id}`).rejects.toThrow(/append-only/);
  });

  test("LOCK: (Postgres) starting a queued build is a compare-and-set: of two starts exactly one wins", async () => {
    const b = await store.insertQueued(newBuild("brief_start"), T0, STALE);
    expect(await store.startBuild(TENANT, b.id, T0)).toBe(false); // no approval recorded yet
    await store.update(TENANT, b.id, { approval_id: "0193a6f2-0000-7000-8000-0000000000a1" }, T0);
    const both = await Promise.all([1, 2].map(() => store.startBuild(TENANT, b.id, T0 + 1)));
    expect(both.sort()).toEqual([false, true]);
    expect((await store.get(TENANT, b.id))!).toMatchObject({ state: "building", started_at: T0 + 1 });
    expect(await store.startBuild(TENANT, b.id, T0 + 2)).toBe(false);
  });

  test("SHIP: (Postgres) deployed_at is set once; a second deploy finds it set", async () => {
    const b = await store.insertQueued(newBuild("brief_ship"), T0, STALE);
    await store.update(TENANT, b.id, { state: "ready", ended_at: T0 + 1 }, T0 + 1);
    const both = await Promise.all([1, 2].map(() => store.markDeployed(TENANT, b.id, T0 + 2)));
    expect(both.sort()).toEqual([false, true]);
    expect((await store.get(TENANT, b.id))!.deployed_at).toBe(T0 + 2);
  });

  test("HELDOUT: (Postgres) a held-out hash used by a build of the brief is remembered", async () => {
    const nb = newBuild("brief_held");
    await store.insertQueued(nb, T0, STALE);
    expect(await store.heldOutUsed(TENANT, "brief_held", nb.bound_hashes["held_out_hash"]!)).toBe(true);
    expect(await store.heldOutUsed(TENANT, "brief_held", "e".repeat(64))).toBe(false);
    expect(await store.heldOutUsed(OTHER_TENANT, "brief_held", nb.bound_hashes["held_out_hash"]!)).toBe(false);
  });

  test("HELDOUT: (Postgres) a new build bound to a held-out hash an earlier build used is refused, also after stale recovery, and recovers nothing", async () => {
    const first = newBuild("brief_held_again");
    await store.insertQueued(first, T0, STALE);
    const same = { ...newBuildRaw("brief_held_again"), bound_hashes: { ...first.bound_hashes } };
    // live: the lock answers first
    await expect(store.insertQueued(same, T0 + 1, STALE)).rejects.toBeInstanceOf(BuildConflict);
    // stale: the reuse is refused and the stale build is left as it was (one transaction)
    await expect(store.insertQueued({ ...same, id: uuid() }, T0 + STALE + 1, STALE)).rejects.toBeInstanceOf(HeldOutUsed);
    expect((await store.get(TENANT, first.id))!.state).toBe("queued");
    // with a fresh held-out check the stale build is recovered and the new one starts
    await store.insertQueued(newBuild("brief_held_again"), T0 + STALE + 1, STALE);
    expect((await store.get(TENANT, first.id))!.state).toBe("infra_failed");
  });

  test("READY: (Postgres) attempts round-trip with check groups and artifact facts", async () => {
    const b = await store.insertQueued(newBuild("brief_att"), T0, STALE);
    const att = { tenant_id: TENANT, id: uuid(), build_id: b.id, ordinal: 1, sandbox_provider: "docker", sandbox_id: "sbx_1", outcome: "pass" as const, spent_usd4: 1_234, tries: 2, turns: 7, frozen_pass: true, held_out_pass: true, check_groups: [{ name: "frozen", passed: 1, failed: 0 }], artifact_sha256: "f".repeat(64), artifact_bytes: 42, artifact_files: ["slug.ts"], note: "passed every check" };
    await store.putAttempt(att);
    await store.putAttempt({ ...att, turns: 8 });
    expect(await store.attempts(TENANT, b.id)).toEqual([{ ...att, turns: 8 }]);
  });

  test("RLS: (Postgres) every builder table has row level security enabled and forced", async () => {
    const rows = await admin`SELECT c.relname, c.relrowsecurity, c.relforcerowsecurity FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = ${SCHEMA} AND c.relkind = 'r' ORDER BY c.relname`;
    expect(rows.map((r: { relname: string; relrowsecurity: boolean; relforcerowsecurity: boolean }) => [r.relname, r.relrowsecurity, r.relforcerowsecurity])).toEqual([...TABLES].sort().map((t) => [t, true, true]));
    expect((await appSql`SELECT current_user AS u`)[0].u).toBe(ROLE);
  });

  test("RLS: (Postgres) as the non-owner role, another tenant's rows are invisible in all five tables", async () => {
    // one build of TENANT with a row in every table, written through the store as the app role
    const b = await app.insertQueued(newBuild("brief_rls_all"), T0, STALE);
    await app.putAttempt({ tenant_id: TENANT, id: uuid(), build_id: b.id, ordinal: 1, sandbox_provider: "docker", sandbox_id: null, outcome: "pass", spent_usd4: 100, tries: 1, turns: 1, frozen_pass: true, held_out_pass: true, check_groups: [], artifact_sha256: null, artifact_bytes: 0, artifact_files: [], note: "" });
    expect(await app.reserve({ tenant_id: TENANT, build_id: b.id, attempt_id: "rls1", call_id: "attempt:rls1", kind: "model", usd4: 100, ceiling_usd4: 37_000 }, T0)).toBe(true);
    await app.settle({ tenant_id: TENANT, build_id: b.id, call_id: "attempt:rls1", idempotency_key: "attempt:rls1", scope: "build", usd4: 100 }, T0);
    await app.update(TENANT, b.id, { state: "ready", receipt: { build_id: b.id }, receipt_hash: "e".repeat(64), ended_at: T0 }, T0);
    const count = (tenant: string | null) =>
      appSql.begin(async (tx) => {
        if (tenant !== null) await tx`SELECT set_config('app.tenant_id', ${tenant}, true)`;
        const out: Record<string, number> = {};
        for (const t of TABLES) out[t] = (await tx.unsafe(`SELECT count(*)::int AS n FROM ${t} WHERE tenant_id = '${TENANT}'`))[0].n;
        return out;
      });
    expect(await count(OTHER_TENANT)).toEqual(Object.fromEntries(TABLES.map((t) => [t, 0])));
    expect(await count(null)).toEqual(Object.fromEntries(TABLES.map((t) => [t, 0])));
    const own = await count(TENANT);
    for (const t of TABLES) expect([t, own[t]! > 0]).toEqual([t, true]);
    // another tenant cannot change the row: the update matches nothing, read back as its own tenant it is unchanged
    const updated = await appSql.begin(async (tx) => {
      await tx`SELECT set_config('app.tenant_id', ${OTHER_TENANT}, true)`;
      return tx`UPDATE builds SET state = 'failed' WHERE id = ${b.id} RETURNING id`;
    });
    expect(updated).toHaveLength(0);
    expect((await app.get(TENANT, b.id))!.state).toBe("ready");
  });

  test("LOCK: (Postgres, as the non-owner role) the lock race and stale recovery hold under RLS", async () => {
    const rs = await Promise.allSettled([newBuild("brief_role_race"), newBuild("brief_role_race")].map((x) => app.insertQueued(x, T0, STALE)));
    expect(rs.filter((r) => r.status === "fulfilled")).toHaveLength(1);
    expect((rs.find((r) => r.status === "rejected") as PromiseRejectedResult).reason).toBeInstanceOf(BuildConflict);
    const later = T0 + STALE + 1;
    const again = await Promise.allSettled([newBuild("brief_role_race"), newBuild("brief_role_race")].map((x) => app.insertQueued(x, later, STALE)));
    expect(again.filter((r) => r.status === "fulfilled")).toHaveLength(1);
    const won = (rs.find((r) => r.status === "fulfilled") as PromiseFulfilledResult<{ id: string }>).value;
    expect((await app.get(TENANT, won.id))!.state).toBe("infra_failed");
  });

  test("CAP: (Postgres, as the non-owner role) three parallel reservations cannot exceed the remaining cap; the ledger stays append-only", async () => {
    const b = await app.insertQueued(newBuild("brief_role_cap"), T0, STALE);
    const got = await Promise.all([1, 2, 3].map((i) => app.reserve({ tenant_id: TENANT, build_id: b.id, attempt_id: `r${i}`, call_id: `attempt:r${i}`, kind: "model", usd4: 7_000, ceiling_usd4: 17_000 }, T0)));
    expect(got.filter(Boolean)).toHaveLength(2);
    const key = `attempt:r${got.indexOf(true) + 1}`;
    await app.settle({ tenant_id: TENANT, build_id: b.id, call_id: key, idempotency_key: key, scope: "build", usd4: 7_000 }, T0 + 1);
    await expect(
      appSql.begin(async (tx) => {
        await tx`SELECT set_config('app.tenant_id', ${TENANT}, true)`;
        await tx`DELETE FROM budget_entries WHERE scope_id = ${b.id}`;
      }),
    ).rejects.toThrow();
  });

});
