// /v1/records/* and /v1/review/* on Postgres (carried from old s36 review.test.ts API tests, as v2 routes).
import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { handleUserModelRequest, type UserModelAuth } from "../../src/http/handlers.ts";
import { listOpportunities, listReviewAnswers } from "../../src/store/repository.ts";
import { runMemberUpdate, writeWeekNarrative } from "../../src/store/job.ts";
import type { TenantContext } from "../../src/store/tenant.ts";
import { fixtureWeek, MONDAYS, SEED } from "../fixtures/window.ts";
import { estimateFor, HAS_DB, seedFourWeeks, testDb, type TestDb } from "./db.ts";

let db: TestDb;
let NOW = 0;
beforeAll(async () => {
  if (!HAS_DB) return;
  db = await testDb("api");
  NOW = await seedFourWeeks(db, db.A1, db.workspaceA);
});
afterAll(async () => {
  if (HAS_DB) await db.cleanup();
});

const auth = (c: TenantContext): UserModelAuth => ({ tenantId: c.tenantId, memberId: c.memberId, principalId: c.principalId, tenantRole: c.tenantRole });
async function call(path: string, method = "GET", body?: unknown, raw?: string, ctx?: TenantContext): Promise<{ status: number; body: any } | null> {
  const init: RequestInit = { method, headers: { "content-type": "application/json" } };
  if (raw !== undefined) init.body = raw;
  else if (body !== undefined) init.body = JSON.stringify(body);
  const res = await handleUserModelRequest(new Request(`https://offload.test${path}`, init), auth(ctx ?? db.A1), { runInTenant: db.run, now: () => NOW });
  if (res === null) return null;
  const text = await res.text();
  return { status: res.status, body: text === "" ? null : JSON.parse(text) };
}
const W = "2026-W45";

describe.skipIf(!HAS_DB)("p43b records and review routes", () => {
  test("API: GET /v1/review/week?w= answers the week review; future week 404; malformed 400", async () => {
    const r = (await call(`/v1/review/week?w=${W}`))!;
    expect(r.status).toBe(200);
    expect(r.body.iso_week).toBe(W);
    expect(typeof r.body.sentence).toBe("string");
    expect(r.body.sentence.length).toBeGreaterThan(0);
    expect(r.body.tiles.length).toBeGreaterThanOrEqual(3);
    for (const t of r.body.tiles) {
      expect(t.id).toMatch(/^fig_[0-9a-f]{16}$/);
      expect(t.arithmetic.length).toBeGreaterThan(0);
    }
    expect(r.body.questions.length).toBeGreaterThan(0);
    expect(r.body.questions.length).toBeLessThanOrEqual(4);
    expect((await call("/v1/review/week?w=2026-W47"))!.status).toBe(404);
    expect((await call("/v1/review/week?w=2026-W46"))!.status).toBe(404);
    expect((await call("/v1/review/week?w=45"))!.status).toBe(400);
    expect((await call("/v1/review/week"))!.status).toBe(400);
  });

  test("API: errors use the envelope { error: { code, message, request_id } }", async () => {
    const r = (await call("/v1/review/week?w=2026-W47"))!;
    expect(Object.keys(r.body)).toEqual(["error"]);
    expect(Object.keys(r.body.error).sort()).toEqual(["code", "message", "request_id"]);
    expect(r.body.error.code).toBe("not_found");
    expect(r.body.error.request_id).toMatch(/^req_[0-9A-HJKMNP-TV-Z]{26}$/);
    expect((await call("/v1/review/week?w=nope"))!.body.error.code).toBe("invalid_request");
  });

  test("API: GET /v1/records/days/{date} answers the day record; unknown day 404; malformed 400", async () => {
    const d = (await call("/v1/records/days/2026-11-03"))!;
    expect(d.status).toBe(200);
    expect(d.body.day).toBe("2026-11-03");
    expect(d.body.episode_ids.length).toBeGreaterThan(0);
    expect(d.body.totals.active_minutes.id).toMatch(/^fig_[0-9a-f]{16}$/);
    expect(d.body.source_purged_at).toBeNull();
    expect((await call("/v1/records/days/2026-01-01"))!.status).toBe(404);
    expect((await call("/v1/records/days/2026-02-30"))!.status).toBe(400);
    expect((await call("/v1/records/days/yesterday"))!.status).toBe(400);
  });

  test("API: GET /v1/records/weeks, months and quarters answer stored records; future 404; malformed 400", async () => {
    const w = (await call(`/v1/records/weeks/${W}`))!;
    expect(w.status).toBe(200);
    expect(w.body.iso_week).toBe(W);
    expect(w.body.hours.total.unit).toBe("hours");
    expect(w.body.weeks_observed).toBe(4);
    expect((await call("/v1/records/weeks/2026-W47"))!.status).toBe(404);
    expect((await call("/v1/records/weeks/2025-W53"))!.status).toBe(400);
    const m = (await call("/v1/records/months/2026-10"))!;
    expect(m.status).toBe(200);
    expect(m.body.weeks).toEqual(["2026-W42", "2026-W43", "2026-W44"]);
    expect((await call("/v1/records/months/2026-12"))!.status).toBe(404);
    expect((await call("/v1/records/months/2026-13"))!.status).toBe(400);
    const q = (await call("/v1/records/quarters/2026-Q4"))!;
    expect(q.status).toBe(200);
    expect(q.body.weeks.length).toBe(4);
    expect((await call("/v1/records/quarters/2026-Q5"))!.status).toBe(400);
  });

  test("API: POST /v1/review/answers stores the answer; not_now takes the task out of the questions", async () => {
    const before = (await call(`/v1/review/week?w=${W}`))!.body;
    const top = before.questions[0].subject_key;
    const r = (await call("/v1/review/answers", "POST", { iso_week: W, subject_key: top, question_kind: "opportunity", answer: "not_now" }))!;
    expect(r.status).toBe(200);
    expect(r.body).toEqual({ iso_week: W, subject_key: top, question_kind: "opportunity", answer: "not_now", goal_id: null, answered_at: new Date(NOW).toISOString() });
    const after = (await call(`/v1/review/week?w=${W}`))!.body;
    expect(after.questions.some((q: any) => q.subject_key === top)).toBe(false);
    const stored = await db.run(db.A1, (tx) => listReviewAnswers(tx));
    expect(stored.some((a) => a.subject_key === top && a.answer === "not_now")).toBe(true);
    const opp = (await db.run(db.A1, (tx) => listOpportunities(tx, W))).find((o) => o.task_key === top)!;
    expect(opp.state).toBe("not_now");
    // A later keep reopens it (latest answer wins).
    await call("/v1/review/answers", "POST", { iso_week: W, subject_key: top, question_kind: "opportunity", answer: "keep" });
    expect((await call(`/v1/review/week?w=${W}`))!.body.questions.some((q: any) => q.subject_key === top && q.answered === "keep")).toBe(true);
  });

  test("API: bad answers are 400 (schema_invalid for the shape, invalid_request for an unknown goal or a future week)", async () => {
    const ok = { iso_week: W, subject_key: "k_0123456789ab", question_kind: "opportunity", answer: "keep" };
    const cases: Array<[unknown, string]> = [
      [{ ...ok, answer: "maybe" }, "schema_invalid"],
      [{ ...ok, iso_week: "nope" }, "schema_invalid"],
      [{ ...ok, subject_key: "k_x" }, "schema_invalid"],
      [{ ...ok, goal_id: "g_9999999999" }, "invalid_request"],
      [{ ...ok, iso_week: "2026-W47" }, "invalid_request"],
    ];
    for (const [body, code] of cases) {
      const r = (await call("/v1/review/answers", "POST", body))!;
      expect({ body, status: r.status, code: r.body.error.code }).toEqual({ body, status: 400, code });
    }
    const broken = (await call("/v1/review/answers", "POST", undefined, "{nope"))!;
    expect([broken.status, broken.body.error.code]).toEqual([400, "invalid_request"]);
  });

  test("API: a goal named in a review answer sets alignment 1 at the next ranking", async () => {
    const p = (await call("/v1/profile", "PATCH", { goals: ["Close customers"] }))!;
    const goalId = p.body.goals[0].id;
    const opps = await db.run(db.A1, (tx) => listOpportunities(tx, W));
    const target = opps.find((o) => o.state === "open" && o.score > 0)!;
    expect(target.factors.alignment.value).toBe(0);
    const r = (await call("/v1/review/answers", "POST", { iso_week: W, subject_key: target.task_key, question_kind: "opportunity", answer: "keep", goal_id: goalId }))!;
    expect(r.status).toBe(200);
    const fx = fixtureWeek(MONDAYS[3], { seed: SEED + 3 });
    await db.run(db.A1, (tx) => runMemberUpdate(tx, { window: fx.window, now: NOW, workspaceId: db.workspaceA, estimateFor }));
    const o = (await db.run(db.A1, (tx) => listOpportunities(tx, W))).find((x) => x.task_key === target.task_key)!;
    expect(o.factors.alignment.value).toBe(1);
    expect(o.factors.goal_weight.value).toBe(1.5);
    expect(o.goal_id).toBe(goalId);
  });

  test("API: the review sentence is the stored narrative once a checked model sentence is written; others are refused", async () => {
    const week = (await call(`/v1/records/weeks/${W}`))!.body;
    const bad = await writeWeekNarrative(db.run, db.A1, W, async () => "You worked 999 hours this week.");
    expect(bad).toBe("code");
    expect((await call(`/v1/review/week?w=${W}`))!.body.sentence).toContain(String(week.hours.total.value));
    let prompt = "";
    const good = `A steady week: ${week.hours.total.value} h of active time.`;
    expect(await writeWeekNarrative(db.run, db.A1, W, async (p) => { prompt = p; return good; })).toBe("model");
    expect(prompt).toContain("<week_record>");
    expect((await call(`/v1/review/week?w=${W}`))!.body.sentence).toBe(good);
    expect((await call(`/v1/records/weeks/${W}`))!.body.narrative).toBe(good);
    expect(await writeWeekNarrative(db.run, db.A1, "2026-W30", async () => good)).toBe("none");
  });

  test("API: paths and methods it does not own return null", async () => {
    expect(await call("/v1/today")).toBeNull();
    expect(await call("/v1/profile", "DELETE")).toBeNull();
    expect(await call("/v1/records/days")).toBeNull();
    expect(await call("/v1/review/answers", "GET")).toBeNull();
  });
});
