import { afterAll, beforeAll, expect, test } from "bun:test";
import { cpSync, mkdtempSync, readdirSync, rmSync, writeFileSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { Pool } from "pg";
import { MIGRATIONS_DIR, MigrationChecksumError, ensurePartitions, loadConfig, migrate, ulid, withTenant } from "../../src/index.ts";
import { freshDatabase, pgTenantFixture, type PgTenantFixture } from "@offload/testkit";

let fx: PgTenantFixture;
beforeAll(async () => {
  fx = await pgTenantFixture();
});
afterAll(async () => {
  await fx?.close();
});

const files = () => readdirSync(MIGRATIONS_DIR).filter((f) => /^\d{4}_[a-z0-9_]+\.sql$/.test(f)).sort();

async function obsInsert(pool: Pool, t: PgTenantFixture["a"], day: string, objectId = ulid()): Promise<void> {
  await withTenant(pool, { tenantId: t.tenantId, principalId: t.owner, memberId: t.owner, tenantRole: "owner" }, async (tx) => {
    await tx.query(
      `insert into observations (tenant_id, device_id, object_id, day, member_id, ts, kind)
       values ($1, $2, $3, $4::date, $5, ($4::date + time '12:00') at time zone 'UTC', 'focus')
       on conflict (tenant_id, device_id, object_id, day) do nothing`,
      [t.tenantId, t.devices.owner, objectId, day, t.owner],
    );
  });
}

test("MIGRATE: migrations apply in order on an empty database", async () => {
  const applied = await freshDatabase();
  expect(files().length).toBeGreaterThanOrEqual(4);
  expect(applied).toEqual(files().map((f) => f.slice(0, 4)));
  const rows = (await fx.admin.query("select version, name, checksum from schema_migrations order by applied_at, version")).rows;
  expect(rows.map((r) => r.version)).toEqual(files().map((f) => f.slice(0, 4)));
  for (const r of rows) expect(r.checksum).toMatch(/^[0-9a-f]{64}$/);
  // Running again applies nothing.
  const again = await freshDatabase({ reset: false });
  expect(again).toEqual([]);
  // Everything in public is owned by offload_migrator.
  const owners = (await fx.admin.query(
    `select distinct pg_get_userbyid(c.relowner) as o from pg_class c join pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'public' and c.relkind in ('r','p','i','S','v')`,
  )).rows.map((r) => r.o);
  expect(owners).toEqual(["offload_migrator"]);
  await fx.close();
  fx = await pgTenantFixture();
});

test("MIGRATE: a changed applied migration fails its checksum", async () => {
  const dir = mkdtempSync(join(tmpdir(), "offload-migrations-"));
  try {
    cpSync(MIGRATIONS_DIR, dir, { recursive: true });
    const first = files()[0]!;
    writeFileSync(join(dir, first), readFileSync(join(dir, first), "utf8") + "\n-- edited after it was applied\n");
    const c = await fx.migrator.connect();
    try {
      const err = await migrate(c, { dir }).then(() => null, (e: unknown) => e);
      expect(err).toBeInstanceOf(MigrationChecksumError);
      expect((err as MigrationChecksumError).version).toBe(first.slice(0, 4));
      // The unchanged directory still passes.
      expect(await migrate(c)).toEqual([]);
    } finally {
      c.release();
    }
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("MIGRATE: observations is partitioned by day with the day in the primary key", async () => {
  for (const table of ["observations", "observation_texts"]) {
    const part = (await fx.admin.query(
      `select pg_get_partkeydef(c.oid) as k, c.relkind from pg_class c where c.relname = $1 and c.relnamespace = 'public'::regnamespace`,
      [table],
    )).rows[0];
    expect(part.relkind).toBe("p");
    expect(part.k).toBe("RANGE (day)");
    const pk = (await fx.admin.query(
      `select array_agg(a.attname::text order by k.ord) as cols
       from pg_constraint con
       cross join lateral unnest(con.conkey) with ordinality as k(attnum, ord)
       join pg_attribute a on a.attrelid = con.conrelid and a.attnum = k.attnum
       where con.conrelid = $1::regclass and con.contype = 'p'`,
      [table],
    )).rows[0].cols;
    expect(pk).toEqual(["tenant_id", "device_id", "object_id", "day"]);
  }
  // ON CONFLICT on the key works: a retry of the same object is a no-op.
  const id = ulid();
  await obsInsert(fx.app, fx.a, "2026-11-10", id);
  await obsInsert(fx.app, fx.a, "2026-11-10", id);
  const n = (await fx.admin.query("select count(*)::int as n from observations where object_id = $1", [id])).rows[0].n;
  expect(n).toBe(1);
});

test("MIGRATE: an insert for a day with no partition lands in DEFAULT", async () => {
  const id = ulid();
  await obsInsert(fx.app, fx.a, "2031-01-05", id);
  const r = (await fx.admin.query("select tableoid::regclass::text as part from observations where object_id = $1", [id])).rows[0];
  expect(r.part).toBe("observations_default");
});

test("MIGRATE: ensurePartitions forces RLS on every new partition", async () => {
  const id = ulid();
  await obsInsert(fx.app, fx.a, "2031-02-02", id);
  const created = await withTenant(
    fx.retention,
    { tenantId: fx.a.tenantId, principalId: "retention", memberId: null, tenantRole: "service", memberScope: "tenant" },
    (tx) => ensurePartitions(tx, "2031-02-01", 3),
  );
  expect(created.sort()).toEqual([
    "observation_texts_p20310201", "observation_texts_p20310202", "observation_texts_p20310203",
    "observations_p20310201", "observations_p20310202", "observations_p20310203",
  ]);
  for (const p of created) {
    const c = (await fx.admin.query("select relrowsecurity, relforcerowsecurity, pg_get_userbyid(relowner) as o from pg_class where relname = $1", [p])).rows[0];
    expect(c).toEqual({ relrowsecurity: true, relforcerowsecurity: true, o: "offload_migrator" });
    const pols = (await fx.admin.query("select polname, polpermissive from pg_policy where polrelid = $1::regclass order by polname", [p])).rows;
    expect(pols).toEqual([
      { polname: "member_isolation", polpermissive: false },
      { polname: "tenant_isolation", polpermissive: true },
    ]);
  }
  // The row that waited in DEFAULT moved into its day's partition.
  const r = (await fx.admin.query("select tableoid::regclass::text as part from observations where object_id = $1", [id])).rows[0];
  expect(r.part).toBe("observations_p20310202");
  // Idempotent.
  const again = await withTenant(
    fx.retention,
    { tenantId: fx.a.tenantId, principalId: "retention", memberId: null, tenantRole: "service", memberScope: "tenant" },
    (tx) => ensurePartitions(tx, "2031-02-01", 3),
  );
  expect(again).toEqual([]);
  // offload_app cannot create partitions.
  const denied = await withTenant(fx.app, fx.ctx(fx.a, fx.a.owner), (tx) => ensurePartitions(tx, "2031-03-01", 1)).then(() => null, (e: Error) => e);
  expect(denied?.message).toMatch(/permission denied/);
});

test("MIGRATE: config reads TTLs and DATABASE_URL with the documented defaults", () => {
  const d = loadConfig({});
  expect(d).toEqual({ databaseUrl: undefined, rawTtlDays: 30, textTtlDays: 7, contentTtlDays: 30 });
  const c = loadConfig({ OFFLOAD_RAW_TTL_DAYS: "14", OFFLOAD_TEXT_TTL_DAYS: "3", OFFLOAD_CONTENT_TTL_DAYS: "21", DATABASE_URL: "postgres://x@h/db" });
  expect(c).toEqual({ databaseUrl: "postgres://x@h/db", rawTtlDays: 14, textTtlDays: 3, contentTtlDays: 21 });
  expect(() => loadConfig({ OFFLOAD_TEXT_TTL_DAYS: "0" })).toThrow(/OFFLOAD_TEXT_TTL_DAYS/);
  expect(() => loadConfig({ OFFLOAD_RAW_TTL_DAYS: "thirty" })).toThrow(/OFFLOAD_RAW_TTL_DAYS/);
});
