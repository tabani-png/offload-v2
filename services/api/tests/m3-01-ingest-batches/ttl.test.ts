import { afterAll, beforeAll, expect, test } from "bun:test";
import { sha256Hex } from "@offload/contracts";
import { ensurePartitions, loadConfig, ulid, withTenant } from "@offload/db";
import { RETENTION_CRON, runRetentionPurge } from "../../src/index.ts";
import { makeHarness, type Harness, type TestDevice } from "./harness.ts";

let h: Harness;
beforeAll(async () => {
  h = await makeHarness();
  // Daily partitions for 1 October to 13 November; 30 September has none, so its rows sit in the default partition.
  await withTenant(h.fx.retention, { tenantId: h.fx.a.tenantId, principalId: "retention", memberId: null, tenantRole: "service" }, (tx) =>
    ensurePartitions(tx, "2026-10-01", 44));
});
afterAll(async () => {
  await h?.close();
});

const TODAY = "2026-11-14";
const dayOf = (age: number) => new Date(Date.parse(`${TODAY}T00:00:00Z`) - age * 86_400_000).toISOString().slice(0, 10);

/** One focus row per age (days before today), as the ingest route would have written it. */
async function seedRaw(dev: TestDevice, ages: number[]): Promise<void> {
  await withTenant(h.fx.app, h.fx.ctx(dev.tenant, dev.memberId), async (tx) => {
    for (const age of ages) {
      await tx.query(
        `insert into observations (tenant_id, device_id, object_id, day, member_id, ts, kind, app_bundle_id, app_name)
         values ($1, $2, $3, $4::date, $5, ($4::date + time '09:00') at time zone 'UTC', 'focus', 'com.apple.mail', 'Mail')`,
        [dev.tenant.tenantId, dev.deviceId, ulid(), dayOf(age), dev.memberId],
      );
    }
  });
}

async function seedText(dev: TestDevice, ages: number[]): Promise<void> {
  await withTenant(h.fx.app, h.fx.ctx(dev.tenant, dev.memberId), async (tx) => {
    for (const age of ages) {
      await tx.query(
        `insert into observation_texts (tenant_id, device_id, object_id, day, member_id, ts, text, text_hash, text_source, app_bundle_id)
         values ($1, $2, $3, $4::date, $5, ($4::date + time '10:00') at time zone 'UTC', 'Invoice <doc:h_0123456789abcdef>', $6, 'ax', 'com.apple.mail')`,
        [dev.tenant.tenantId, dev.deviceId, ulid(), dayOf(age), dev.memberId, sha256Hex(`t${age}`)],
      );
    }
  });
}

/** Ages (days before today) still stored for the device, sorted. */
async function ages(table: "observations" | "observation_texts", dev: TestDevice): Promise<number[]> {
  const r = await h.fx.admin.query(`select day::text as day from ${table} where device_id = $1`, [dev.deviceId]);
  return r.rows.map((x) => Math.round((Date.parse(`${TODAY}T00:00:00Z`) - Date.parse(`${x.day}T00:00:00Z`)) / 86_400_000)).sort((a, b) => a - b);
}

const purge = (env: Record<string, string> = {}) =>
  runRetentionPurge({ pool: h.fx.retention, clock: { now: () => new Date(`${TODAY}T03:15:00.000Z`) }, config: loadConfig(env) });

const partitionExists = async (name: string) =>
  (await h.fx.admin.query("select to_regclass($1) is not null as e", [`public.${name}`])).rows[0].e as boolean;

test("TTL: observations older than the raw TTL are dropped by the purge job and logged", async () => {
  expect(RETENTION_CRON).toBe("15 3 * * *");
  const dev = await h.device(h.fx.a, h.fx.a.owner);
  // 45 days old sits in the default partition, 35 and 31 in daily partitions that expire whole; 30 is the last kept day.
  await seedRaw(dev, [45, 35, 31, 30, 29, 15, 5, 0]);
  expect(await partitionExists("observations_p20261014")).toBe(true);
  const result = await purge();
  expect(await ages("observations", dev)).toEqual([0, 5, 15, 29, 30]);
  expect(await partitionExists("observations_p20261014")).toBe(false);
  expect(await partitionExists("observations_p20261015")).toBe(true);
  expect(result.partitionsDropped).toContain("observations_p20261014");
  // The job also creates the next daily partitions.
  expect(await partitionExists("observations_p20261116")).toBe(true);
  const log = (await h.fx.admin.query("select scope, rows_deleted, requested_by from purge_log where tenant_id = $1 and scope in ('raw_ttl', 'text_ttl') order by at, scope", [h.fx.a.tenantId])).rows;
  expect(log).toEqual([{ scope: "raw_ttl", rows_deleted: { observations: 3 }, requested_by: "retention" }]);
  // Another tenant with nothing expired gets no log row.
  expect((await h.fx.admin.query("select count(*)::int as n from purge_log where tenant_id = $1 and scope in ('raw_ttl', 'text_ttl')", [h.fx.b.tenantId])).rows[0].n).toBe(0);
  // A second run finds nothing more.
  await purge();
  expect(await ages("observations", dev)).toEqual([0, 5, 15, 29, 30]);
});

test("TTL: text snapshots older than the text TTL are dropped while metadata stays", async () => {
  const dev = await h.device(h.fx.b, h.fx.b.owner);
  await seedRaw(dev, [8, 7, 0]);
  await seedText(dev, [8, 7, 6, 0]);
  await purge();
  expect(await ages("observation_texts", dev)).toEqual([0, 6, 7]);
  expect(await ages("observations", dev)).toEqual([0, 7, 8]);
  const log = (await h.fx.admin.query("select scope, rows_deleted from purge_log where tenant_id = $1 and scope = 'text_ttl'", [h.fx.b.tenantId])).rows;
  expect(log).toEqual([{ scope: "text_ttl", rows_deleted: { observation_texts: 1 } }]);
});

test("TTL: changing OFFLOAD_RAW_TTL_DAYS changes what is dropped", async () => {
  const dev = await h.device(h.fx.a, h.fx.a.member);
  await seedRaw(dev, [20, 12, 11, 10, 3]);
  await seedText(dev, [5, 3, 1]);
  await purge();
  expect(await ages("observations", dev)).toEqual([3, 10, 11, 12, 20]);
  expect(await ages("observation_texts", dev)).toEqual([1, 3, 5]);
  await purge({ OFFLOAD_RAW_TTL_DAYS: "10", OFFLOAD_TEXT_TTL_DAYS: "2" });
  expect(await ages("observations", dev)).toEqual([3, 10]);
  expect(await ages("observation_texts", dev)).toEqual([1]);
  await purge({ OFFLOAD_RAW_TTL_DAYS: "2" });
  expect(await ages("observations", dev)).toEqual([]);
  // A bad value is refused, not guessed.
  expect(() => loadConfig({ OFFLOAD_RAW_TTL_DAYS: "0" })).toThrow();
});
