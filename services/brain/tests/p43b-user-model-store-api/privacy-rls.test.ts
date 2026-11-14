// Privacy of the stored user model and the tenant and member walls (ADR 0013; SECURITY_PRIVACY section 13).
import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { handleUserModelRequest } from "../../src/http/handlers.ts";
import { MEMBER_ISOLATED_TABLES } from "../../src/store/migrate.ts";
import type { TenantContext } from "../../src/store/tenant.ts";
import { fixtureWeek, MONDAYS, SEED } from "../fixtures/window.ts";
import { dumpAll, HAS_DB, seedFourWeeks, testDb, type TestDb } from "./db.ts";

let db: TestDb;
let NOW = 0;
beforeAll(async () => {
  if (!HAS_DB) return;
  db = await testDb("rls");
  NOW = await seedFourWeeks(db, db.A1, db.workspaceA);
  const deps = { runInTenant: db.run, now: () => NOW };
  const a = { tenantId: db.A1.tenantId, memberId: db.A1.memberId, principalId: db.A1.principalId, tenantRole: "owner" };
  await handleUserModelRequest(new Request("https://offload.test/v1/profile", { method: "PATCH", body: JSON.stringify({ goals: ["Ship the Mac app"], role: "Founder" }) }), a, deps);
  const review = await (await handleUserModelRequest(new Request("https://offload.test/v1/review/week?w=2026-W45"), a, deps))!.json() as any;
  await handleUserModelRequest(new Request("https://offload.test/v1/review/answers", { method: "POST", body: JSON.stringify({ iso_week: "2026-W45", subject_key: review.questions[0].subject_key, question_kind: "opportunity", answer: "keep" }) }), a, deps);
});
afterAll(async () => {
  if (HAS_DB) await db.cleanup();
});

const count = (ctx: TenantContext | null, table: string) =>
  ctx === null
    ? db.sql.begin(async (tx) => {
        await tx.unsafe(`SET LOCAL search_path TO ${db.schema}`);
        await tx.unsafe(`SET LOCAL ROLE ${db.role}`);
        return ((await tx.unsafe(`SELECT count(*)::int AS n FROM ${table}`)) as Array<{ n: number }>)[0]!.n;
      })
    : db.run(ctx, async (tx) => ((await tx.unsafe(`SELECT count(*)::int AS n FROM ${table}`)) as Array<{ n: number }>)[0]!.n);

describe.skipIf(!HAS_DB)("p43b privacy and isolation", () => {
  test("PRIVACY: no window title, text snapshot, URL or email from the fixture is in any R-model table", async () => {
    const dump = await dumpAll(db, MEMBER_ISOLATED_TABLES);
    const all = JSON.stringify(dump);
    for (const t of MEMBER_ISOLATED_TABLES) expect({ t, rows: dump[t]!.length > 0 }).toEqual({ t, rows: true });
    const leaks: string[] = [];
    for (const [i, monday] of MONDAYS.entries()) {
      const fx = fixtureWeek(monday, { seed: SEED + i, ...(i === 2 ? { without: ["calls"] } : {}) });
      for (const s of fx.raw.titles) if (all.includes(s)) leaks.push(`title ${s}`);
      for (const s of fx.raw.texts) if (all.includes(s)) leaks.push(`text ${s}`);
      for (const s of fx.raw.urls) if (all.includes(s)) leaks.push(`url ${s}`);
      for (const s of fx.raw.emails) if (all.includes(s)) leaks.push(`email ${s}`);
    }
    expect([...new Set(leaks)].slice(0, 5)).toEqual([]);
    expect(/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[a-z]{2,}/.test(all)).toBe(false);
    expect(/https?:\/\//.test(all)).toBe(false);
    const model = JSON.stringify([dump["propositions"], dump["task_ledger"], dump["profiles"], dump["goals"], dump["review_answers"]]);
    expect(/obs_\d{8}_/.test(model)).toBe(false);
  });

  test("RLS: every user-model table has forced RLS, tenant_isolation and a restrictive member_isolation", async () => {
    const rows = await db.sql.unsafe(
      `SELECT c.relname, c.relrowsecurity, c.relforcerowsecurity,
              (SELECT count(*)::int FROM pg_policy p WHERE p.polrelid = c.oid AND p.polname = 'tenant_isolation' AND p.polpermissive) AS tenant,
              (SELECT count(*)::int FROM pg_policy p WHERE p.polrelid = c.oid AND p.polname = 'member_isolation' AND NOT p.polpermissive) AS member
         FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = $1 AND c.relkind IN ('r', 'p') ORDER BY c.relname`, [db.schema]);
    expect(rows.map((r: any) => r.relname).sort()).toEqual([...MEMBER_ISOLATED_TABLES].sort());
    for (const r of rows as any[]) expect([r.relname, r.relrowsecurity, r.relforcerowsecurity, r.tenant, r.member]).toEqual([r.relname, true, true, 1, 1]);
    const owner = await db.sql.unsafe(`SELECT count(*)::int AS n FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = $1 AND pg_get_userbyid(c.relowner) = $2`, [db.schema, db.role]);
    expect(owner[0].n).toBe(0);
  });

  test("RLS: member A2 reads zero rows of member A1 in every table; member_scope tenant reads them", async () => {
    for (const t of MEMBER_ISOLATED_TABLES) {
      expect({ t, a1: (await count(db.A1, t)) > 0 }).toEqual({ t, a1: true });
      expect({ t, a2: await count(db.A2, t) }).toEqual({ t, a2: 0 });
      expect({ t, scope: (await count({ ...db.A2, memberScope: "tenant" }, t)) > 0 }).toEqual({ t, scope: true });
    }
  });

  test("RLS: tenant B reads zero rows of tenant A, and an unset tenant reads zero rows", async () => {
    for (const t of MEMBER_ISOLATED_TABLES) {
      expect({ t, b: await count(db.B1, t) }).toEqual({ t, b: 0 });
      expect({ t, b: await count({ ...db.B1, memberScope: "tenant" }, t) }).toEqual({ t, b: 0 });
      expect({ t, none: await count(null, t) }).toEqual({ t, none: 0 });
    }
  });

  test("RLS: inserting a row for another member or another tenant fails", async () => {
    const insert = (tenant: string, member: string) =>
      `INSERT INTO review_answers (tenant_id, member_id, iso_week, subject_key, question_kind, answer, answered_at) VALUES ('${tenant}', '${member}', '2026-W45', 'k_0123456789ab', 'opportunity', 'keep', now())`;
    const attempt = async (ctx: TenantContext, tenant: string, member: string) => {
      try {
        await db.run(ctx, (tx) => tx.unsafe(insert(tenant, member)));
        return "inserted";
      } catch (e) {
        return String(e);
      }
    };
    expect(await attempt(db.A2, db.A1.tenantId, db.A1.memberId)).toContain("row-level security");
    expect(await attempt(db.B1, db.A1.tenantId, db.B1.memberId)).toContain("row-level security");
    expect(await attempt(db.A2, db.A2.tenantId, db.A2.memberId)).toBe("inserted");
  });
});
