// GET/PATCH /v1/profile on Postgres (carried from old s36 profile.test.ts PROFILE tests, as v2 routes).
import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { handleUserModelRequest, type UserModelAuth } from "../../src/http/handlers.ts";
import { defaultProfile } from "../../src/profile/profile.ts";
import type { TenantContext } from "../../src/store/tenant.ts";
import { HAS_DB, testDb, type TestDb } from "./db.ts";

let db: TestDb;
beforeAll(async () => {
  if (HAS_DB) db = await testDb("profile");
});
afterAll(async () => {
  if (HAS_DB) await db.cleanup();
});

const NOW = Date.UTC(2026, 10, 14, 10);
const auth = (c: TenantContext): UserModelAuth => ({ tenantId: c.tenantId, memberId: c.memberId, principalId: c.principalId, tenantRole: c.tenantRole });
async function call(ctx: TenantContext, method: string, path: string, body?: unknown, raw?: string): Promise<{ status: number; body: any; type: string | null }> {
  const init: RequestInit = { method, headers: { "content-type": "application/json" } };
  if (raw !== undefined) init.body = raw;
  else if (body !== undefined) init.body = JSON.stringify(body);
  const res = await handleUserModelRequest(new Request(`https://offload.test${path}`, init), auth(ctx), { runInTenant: db.run, now: () => NOW });
  if (res === null) return { status: 0, body: null, type: null };
  const text = await res.text();
  return { status: res.status, body: text === "" ? null : JSON.parse(text), type: res.headers.get("content-type") };
}

describe.skipIf(!HAS_DB)("p43b profile routes", () => {
  test("PROFILE: GET /v1/profile answers the defaults when nothing is stored", async () => {
    const r = await call(db.B1, "GET", "/v1/profile");
    expect(r.status).toBe(200);
    expect(r.type).toBe("application/json; charset=utf-8");
    expect(r.body).toEqual(defaultProfile());
  });

  test("PROFILE: PATCH is partial, bumps version and round-trips", async () => {
    const a = await call(db.A1, "PATCH", "/v1/profile", { goals: ["Ship the Mac app", "More deep work"], drains: ["email", "meetings"], autonomy: "draft", timezone: "Asia/Karachi" });
    expect(a.status).toBe(200);
    expect(a.body.version).toBe(1);
    expect(a.body.goals.map((g: any) => g.text)).toEqual(["Ship the Mac app", "More deep work"]);
    expect(a.body.goals[0].id).toMatch(/^g_[0-9a-f]{10}$/);
    const b = await call(db.A1, "PATCH", "/v1/profile", { schedule: { days: ["mon", "tue", "wed", "thu", "fri"], start: "09:00", end: "17:30" } });
    expect(b.body.version).toBe(2);
    expect(b.body.goals.length).toBe(2);
    expect(b.body.autonomy).toBe("draft");
    const g = await call(db.A1, "GET", "/v1/profile");
    expect(g.body).toEqual(b.body);
    expect(g.body.timezone).toBe("Asia/Karachi");
    expect(g.body.review_slot).toEqual({ day: "fri", time: "16:00" });
  });

  test("PROFILE: validation -> 400 schema_invalid (more than 3 goals, over 80 chars, two lines, unknown drain/autonomy/field, bad times)", async () => {
    const before = (await call(db.A2, "GET", "/v1/profile")).body.version;
    const bad = [
      { goals: ["a", "b", "c", "d"] },
      { goals: ["x".repeat(81)] },
      { goals: ["one\ntwo"] },
      { goals: ["Close the deal with dana@fund.example"] },
      { drains: ["email", "sleeping"] },
      { autonomy: "yolo" },
      { favouriteColour: "lime" },
      { learning_paused: true },
      { review_slot: { day: "funday", time: "16:00" } },
      { schedule: { days: ["mon"], start: "25:00", end: "17:00" } },
      { timezone: "Mars/Olympus" },
    ];
    for (const body of bad) {
      const r = await call(db.A2, "PATCH", "/v1/profile", body);
      expect({ body, status: r.status, code: r.body?.error?.code }).toEqual({ body, status: 400, code: "schema_invalid" });
      expect(r.body.error.request_id).toMatch(/^req_[0-9A-HJKMNP-TV-Z]{26}$/);
      expect(typeof r.body.error.message).toBe("string");
    }
    const broken = await call(db.A2, "PATCH", "/v1/profile", undefined, "{nope");
    expect([broken.status, broken.body.error.code]).toEqual([400, "invalid_request"]);
    expect((await call(db.A2, "GET", "/v1/profile")).body.version).toBe(before);
  });

  test("PROFILE: goal ids stay the same when the same goal text is sent again; a removed goal is archived, not deleted", async () => {
    const a = await call(db.A2, "PATCH", "/v1/profile", { goals: ["Ship the Mac app"] });
    const b = await call(db.A2, "PATCH", "/v1/profile", { goals: ["Ship the Mac app", "Less admin"] });
    expect(b.body.goals[0].id).toBe(a.body.goals[0].id);
    const c = await call(db.A2, "PATCH", "/v1/profile", { goals: ["Less admin"] });
    expect(c.body.goals.map((g: any) => g.text)).toEqual(["Less admin"]);
    const rows = await db.sql.unsafe(`SELECT id, archived_at FROM ${db.schema}.goals WHERE member_id = $1 ORDER BY created_at, id`, [db.A2.memberId]);
    const old = rows.find((r: any) => r.id === a.body.goals[0].id);
    expect(old).toBeDefined();
    expect(old.archived_at).not.toBeNull();
  });

  test("PROFILE: the database refuses a fourth active goal", async () => {
    const insert = (id: string) => `INSERT INTO goals (tenant_id, member_id, id, text, created_at) VALUES (current_setting('app.tenant_id')::uuid, current_setting('app.member_id')::uuid, '${id}', 'goal ${id.slice(-1)}', now())`;
    const ids = ["g_000000000a", "g_000000000b", "g_000000000c", "g_000000000d"];
    let err: unknown = null;
    try {
      await db.run(db.B1, async (tx) => {
        for (const id of ids) await tx.unsafe(insert(id));
      });
    } catch (e) {
      err = e;
    }
    expect(String(err)).toContain("at most 3 active goals");
    const n = await db.sql.unsafe(`SELECT count(*)::int AS n FROM ${db.schema}.goals WHERE member_id = $1`, [db.B1.memberId]);
    expect(n[0].n).toBe(0);
  });
});
