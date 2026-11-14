// Review answers, the weekly review payload and the privacy of the whole user model (old s36 review.test.ts and
// privacy.test.ts, restated: no raw observation text anywhere in the derived model).
import { describe, expect, test } from "bun:test";
import { rankOpportunities, type FixEstimate } from "../../src/opportunities/score.ts";
import { applyProfilePatch, defaultProfile } from "../../src/profile/profile.ts";
import { weekSentence } from "../../src/records/narrative.ts";
import { buildRollup } from "../../src/records/rollup.ts";
import { latestAnswers, OPPORTUNITY_ANSWERS, parseReviewAnswer, type ReviewAnswer } from "../../src/review/answers.ts";
import { buildWeekReview } from "../../src/review/week-review.ts";
import { liveWeeks } from "../fixtures/pipeline.ts";
import { WEEKS } from "../fixtures/window.ts";

const L = liveWeeks();
const W = WEEKS[3];
const NOW = L.lastNow;
const ctx = { activeGoalIds: ["g_0123456789"], currentWeek: W, now: NOW };
const k = (name: string) => L.weeks.get(W)!.tasks.find((t) => t.name === name)!.task_key;

describe("p43a review", () => {
  test("REVIEW: an answer is validated (week, subject key, question kind, answer, goal id)", () => {
    const good = parseReviewAnswer({ iso_week: W, subject_key: "k_0123456789ab", question_kind: "opportunity", answer: "not_now" }, ctx);
    expect(good).toEqual({ ok: true, answer: { iso_week: W, subject_key: "k_0123456789ab", question_kind: "opportunity", answer: "not_now", goal_id: null, answered_at: new Date(NOW).toISOString() } });
    const withGoal = parseReviewAnswer({ iso_week: W, subject_key: "k_0123456789ab", question_kind: "opportunity", answer: "other_goal", goal_id: "g_0123456789" }, ctx);
    expect(withGoal.ok && withGoal.answer.goal_id).toBe("g_0123456789");
    const cases: Array<[unknown, string]> = [
      [{ iso_week: "45", subject_key: "k_0123456789ab", question_kind: "opportunity", answer: "keep" }, "schema_invalid"],
      [{ iso_week: "2026-W54", subject_key: "k_0123456789ab", question_kind: "opportunity", answer: "keep" }, "schema_invalid"],
      [{ iso_week: W, subject_key: "k_x", question_kind: "opportunity", answer: "keep" }, "schema_invalid"],
      [{ iso_week: W, subject_key: "k_0123456789ab", question_kind: "opportunity", answer: "maybe" }, "schema_invalid"],
      [{ iso_week: W, subject_key: "k_0123456789ab", question_kind: "opportunity", answer: "yes" }, "schema_invalid"],
      [{ iso_week: W, subject_key: "k_0123456789ab", question_kind: "name", answer: "confirm_name" }, "schema_invalid"],
      [{ iso_week: W, subject_key: "k_0123456789ab", question_kind: "opportunity", answer: "keep", goal_id: "goal-1" }, "schema_invalid"],
      [{ iso_week: W, subject_key: "k_0123456789ab", question_kind: "opportunity", answer: "other_goal" }, "schema_invalid"],
      [{ iso_week: W, subject_key: "k_0123456789ab", question_kind: "opportunity", answer: "keep", extra: 1 }, "schema_invalid"],
      [[1, 2], "schema_invalid"],
      [{ iso_week: W, subject_key: "k_0123456789ab", question_kind: "opportunity", answer: "keep", goal_id: "g_9999999999" }, "invalid_request"],
      [{ iso_week: "2026-W46", subject_key: "k_0123456789ab", question_kind: "opportunity", answer: "keep" }, "invalid_request"],
    ];
    for (const [body, code] of cases) {
      const r = parseReviewAnswer(body, ctx);
      expect({ body, code: r.ok ? "ok" : r.code }).toEqual({ body, code });
    }
  });

  test("REVIEW: the latest answer wins per week and subject", () => {
    const a = (week: string, ans: ReviewAnswer["answer"], at: string): ReviewAnswer => ({ iso_week: week, subject_key: "k_0123456789ab", question_kind: "opportunity", answer: ans, goal_id: null, answered_at: at });
    const latest = latestAnswers([a(W, "keep", "2026-11-06T10:00:00.000Z"), a(W, "never", "2026-11-06T11:00:00.000Z"), a("2026-W44", "not_now", "2026-10-30T10:00:00.000Z"), a(W, "build", "2026-11-06T09:00:00.000Z")]);
    expect(latest.map((x) => [x.iso_week, x.answer])).toEqual([["2026-W44", "not_now"], [W, "never"]]);
  });

  test("REVIEW: the week review has the checked sentence, Figure tiles, the goals and at most 4 open questions", () => {
    const p = applyProfilePatch(defaultProfile(), { goals: ["Ship the Mac app"] }, NOW);
    if (!p.ok) throw new Error(p.message);
    const week = L.weeks.get(W)!;
    const opps = ["Outreach emails", "Update the weekly report", "Review pull requests", "Calls in zoom", "Slack replies", "Reply to about invoice"].map((name, i) => ({ task_key: k(name), name, rank: i + 1, state: i === 1 ? "not_now" : "open" }));
    const answers: ReviewAnswer[] = [{ iso_week: W, subject_key: k("Outreach emails"), question_kind: "opportunity", answer: "keep", goal_id: null, answered_at: "2026-11-06T10:00:00.000Z" }];
    const r = buildWeekReview({ week, goals: p.profile.goals, opportunities: opps, answers });
    expect(r.iso_week).toBe(W);
    expect(r.sentence).toBe(weekSentence(week));
    expect(buildWeekReview({ week: { ...week, narrative: "A steady week." }, goals: [], opportunities: [], answers: [] }).sentence).toBe("A steady week.");
    expect(r.tiles.length).toBeGreaterThanOrEqual(3);
    expect(r.tiles[0]!.id).toBe(week.hours.total.id);
    for (const t of r.tiles) expect(t.id).toMatch(/^fig_[0-9a-f]{16}$/);
    expect(r.goals).toEqual([{ id: p.profile.goals[0]!.id, text: "Ship the Mac app" }]);
    expect(r.questions.length).toBe(4);
    expect(r.questions.map((q) => q.name)).toEqual(["Outreach emails", "Review pull requests", "Calls in zoom", "Slack replies"]);
    expect(r.questions[0]!.answered).toBe("keep");
    expect(r.questions[1]!.answered).toBeNull();
    for (const q of r.questions) {
      expect(q.question_kind).toBe("opportunity");
      expect(q.answers).toEqual([...OPPORTUNITY_ANSWERS]);
    }
  });

  test("PRIVACY: no window title, text, URL or email from the windows is in the user model; observation ids only as evidence", () => {
    const estimates: FixEstimate[] = L.weeks.get(W)!.tasks.filter((t) => t.status !== "gone").map((t) => ({ taskKey: t.task_key, fixKind: "agent_workflow", weeklyHoursSaved: 1, setupHours: 2, ruleConfidence: 0.7, workKind: "email" }));
    const ranked = rankOpportunities({ isoWeek: W, week: L.weeks.get(W)!, recent: [...L.weeks.values()], estimates, drains: [], goals: [], taskVectors: new Map(), answers: [] });
    const rollups = [buildRollup("month", "2026-10", [...L.weeks.values()], ["email"], NOW), buildRollup("quarter", "2026-Q4", [...L.weeks.values()], [], NOW)];
    const model = JSON.stringify({ ledger: L.ledger, propositions: L.propositions, ranked });
    const all = JSON.stringify({ model, days: [...L.days.values()], weeks: [...L.weeks.values()], episodes: L.episodes, rollups });
    const leaks: string[] = [];
    for (const fx of L.fixtures) {
      for (const t of fx.raw.titles) if (all.includes(t)) leaks.push(`title ${t}`);
      for (const t of fx.raw.texts) if (all.includes(t)) leaks.push(`text ${t}`);
      for (const u of fx.raw.urls) if (all.includes(u)) leaks.push(`url ${u}`);
      for (const e of fx.raw.emails) if (all.includes(e)) leaks.push(`email ${e}`);
      for (const id of fx.raw.observationIds.slice(0, 50)) if (model.includes(id)) leaks.push(`observation id in the model ${id}`);
    }
    expect([...new Set(leaks)].slice(0, 5)).toEqual([]);
    expect(/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[a-z]{2,}/.test(all)).toBe(false);
    expect(/https?:\/\//.test(all)).toBe(false);
    expect(L.ledger.every((e) => e.signatures.every((s) => /^[0-9a-f]{16}$/.test(s)))).toBe(true);
  });
});
