// Goal-weighted opportunity score (carried from old s36 review.test.ts SCORE, plus payback and decline rules).
import { describe, expect, test } from "bun:test";
import { bestGoal, isDeclined, opportunityScore, paybackWeeks, rankOpportunities, type FixEstimate, type RankInput } from "../../src/opportunities/score.ts";
import type { ReviewAnswer } from "../../src/review/answers.ts";
import { liveWeeks } from "../fixtures/pipeline.ts";
import { WEEKS } from "../fixtures/window.ts";

const base = { weeklyHoursSaved: 10, persistence: 0.75, confidence: 0.8, paybackWeeks: 1, alignment: 0, advances: false, declined: false, hoursVsBaseline: null as number | null, drainBoost: 0 };

const L = liveWeeks();
const W = WEEKS[3];
const keyOf = (name: string) => L.weeks.get(W)!.tasks.find((t) => t.name === name)!.task_key;
const est = (name: string, weekly: number, setup: number, conf: number, workKind: FixEstimate["workKind"], fixKind = "agent_workflow"): FixEstimate => ({ taskKey: keyOf(name), fixKind, weeklyHoursSaved: weekly, setupHours: setup, ruleConfidence: conf, workKind });
const ESTIMATES: FixEstimate[] = [
  est("Outreach emails", 2, 4, 0.8, "email"),
  est("Update the weekly report", 1.5, 3, 0.7, "sheet", "script"),
  est("Review pull requests", 1, 10, 0.9, "code"),
  est("Calls in zoom", 0.5, 1, 0.5, "meeting", "setup_change"),
  est("Slack replies", 0.3, 1, 0.6, "chat"),
  est("Reply to about invoice", 0.8, 2, 0.6, "email"),
];
const input = (over: Partial<RankInput> = {}): RankInput => ({
  isoWeek: W, week: L.weeks.get(W)!, recent: [...L.weeks.values()], estimates: ESTIMATES, drains: [], goals: [],
  taskVectors: new Map(), answers: [], ...over,
});
const answer = (subject_key: string, iso_week: string, a: ReviewAnswer["answer"], goal_id: string | null = null, at = "2026-11-06T16:00:00.000Z"): ReviewAnswer =>
  ({ iso_week, subject_key, question_kind: "opportunity", answer: a, goal_id, answered_at: at });

describe("p43a opportunity score", () => {
  test("SCORE: hours x persistence x goalWeight x confidence / payback x declinePenalty", () => {
    expect(opportunityScore(base).score).toBe(6);
    expect(opportunityScore({ ...base, alignment: 1, advances: true }).parts.goalWeight).toBe(1.5);
    expect(opportunityScore({ ...base, alignment: 1, advances: true }).score).toBe(9);
    expect(opportunityScore({ ...base, alignment: 1, competes: true }).parts.goalWeight).toBe(0.7);
    expect(opportunityScore({ ...base, paybackWeeks: 3 }).score).toBe(2);
    expect(opportunityScore({ ...base, paybackWeeks: 0.5 }).score).toBe(6);
    expect(opportunityScore({ ...base, drainBoost: 0.1 }).parts.persistence).toBe(0.85);
  });

  test("SCORE: a declined task scores 0 unless its hours rose 50% over baseline", () => {
    expect(opportunityScore({ ...base, declined: true }).score).toBe(0);
    expect(opportunityScore({ ...base, declined: true, hoursVsBaseline: 0.49 }).score).toBe(0);
    expect(opportunityScore({ ...base, declined: true, hoursVsBaseline: 0.5 }).score).toBe(6);
  });

  test("SCORE: an empty profile changes nothing (goalWeight 1, no drain boost)", () => {
    expect(opportunityScore(base).parts.goalWeight).toBe(1);
    const plain = rankOpportunities(input());
    for (const o of plain) {
      expect(o.factors.goal_weight.value).toBe(1);
      expect(o.goal_id).toBeNull();
    }
    expect(JSON.stringify(rankOpportunities(input({ drains: [], goals: [] })))).toBe(JSON.stringify(plain));
    const calls = keyOf("Calls in zoom");
    const plainCalls = plain.find((o) => o.task_key === calls)!.factors.persistence.value;
    expect(plainCalls).toBe(0.75);
    const drained = rankOpportunities(input({ drains: ["meetings"] })).find((o) => o.task_key === calls)!;
    expect(drained.factors.persistence.value).toBe(0.85);
  });

  test("SCORE: paybackWeeks comes from the fix estimate (setup hours / weekly saving)", () => {
    expect(paybackWeeks(10, 10)).toBe(1);
    expect(paybackWeeks(30, 10)).toBe(3);
    expect(paybackWeeks(5, 0)).toBe(Number.POSITIVE_INFINITY);
    const review = rankOpportunities(input()).find((o) => o.task_key === keyOf("Review pull requests"))!;
    expect(review.factors.payback_weeks.value).toBe(10);
    expect(review.factors.payback_weeks.arithmetic).toContain("10");
    // 1 h/week x persistence 1 x goalWeight 1 x 0.9 / 10 weeks
    expect(review.score.value).toBe(0.09);
  });

  test("SCORE: not_now holds for 4 weeks; never and leave_alone hold until a later answer", () => {
    const k = "k_000000000001";
    expect(isDeclined([answer(k, "2026-W42", "not_now")], k, "2026-W42")).toBe(true);
    expect(isDeclined([answer(k, "2026-W42", "not_now")], k, "2026-W45")).toBe(true);
    expect(isDeclined([answer(k, "2026-W42", "not_now")], k, "2026-W46")).toBe(false);
    expect(isDeclined([answer(k, "2026-W42", "never")], k, "2027-W10")).toBe(true);
    expect(isDeclined([answer(k, "2026-W42", "leave_alone")], k, "2027-W10")).toBe(true);
    expect(isDeclined([answer(k, "2026-W42", "never", null, "2026-10-16T16:00:00.000Z"), answer(k, "2026-W44", "keep", null, "2026-10-30T16:00:00.000Z")], k, "2026-W45")).toBe(false);
    expect(isDeclined([answer(k, "2026-W46", "never")], k, "2026-W45")).toBe(false);
    const out = keyOf("Outreach emails");
    const ranked = rankOpportunities(input({ answers: [answer(out, "2026-W45", "not_now")] }));
    const o = ranked.find((x) => x.task_key === out);
    expect(o === undefined || o.score.value === 0).toBe(true);
  });

  test("SCORE: a review answer naming a goal sets alignment to 1", () => {
    const report = keyOf("Update the weekly report");
    const goals = [{ id: "g_0123456789", embedding: [0, 1] }];
    const vectors = new Map([[report, [1, 0]]]);
    const without = rankOpportunities(input({ goals, taskVectors: vectors })).find((o) => o.task_key === report)!;
    expect(without.factors.alignment.value).toBe(0);
    expect(without.goal_id).toBeNull();
    const withGoal = rankOpportunities(input({ goals, taskVectors: vectors, answers: [answer(report, "2026-W45", "keep", "g_0123456789")] })).find((o) => o.task_key === report)!;
    expect(withGoal.factors.alignment.value).toBe(1);
    expect(withGoal.factors.goal_weight.value).toBe(1.5);
    expect(withGoal.goal_id).toBe("g_0123456789");
  });

  test("SCORE: an empty profile reproduces the fix-rule order; top 5, every factor a Figure; confidence is rule confidence x track record", () => {
    const track = new Map([["script", 0.5]]);
    const ranked = rankOpportunities(input({ trackRecord: track }));
    expect(ranked.length).toBe(5);
    ranked.forEach((o, i) => {
      expect(o.rank).toBe(i + 1);
      for (const f of Object.values(o.factors)) {
        expect(f.id).toMatch(/^fig_[0-9a-f]{16}$/);
        expect(f.arithmetic.length).toBeGreaterThan(0);
      }
      if (i > 0) expect(ranked[i - 1]!.score.value).toBeGreaterThanOrEqual(o.score.value);
    });
    const report = ranked.find((o) => o.task_key === keyOf("Update the weekly report"))!;
    expect(report.factors.confidence.value).toBe(0.35);
    const order = ESTIMATES.map((e) => {
      const p = ranked.find((o) => o.task_key === e.taskKey)?.factors.persistence.value ?? 0;
      const c = e.ruleConfidence * (track.get(e.fixKind) ?? 1);
      return { k: e.taskKey, s: (e.weeklyHoursSaved * p * c) / Math.max(1, e.setupHours / e.weeklyHoursSaved) };
    }).sort((a, b) => b.s - a.s || (a.k < b.k ? -1 : 1)).slice(0, 5).map((x) => x.k);
    expect(ranked.map((o) => o.task_key)).toEqual(order);
  });

  test("SCORE: alignment is the best goal's embedding cosine, clamped to 0..1", () => {
    expect(bestGoal([], [1, 0])).toEqual({ goalId: null, alignment: 0 });
    expect(bestGoal([{ id: "g_a", embedding: [1, 0] }, { id: "g_b", embedding: [0.6, 0.8] }], [0.6, 0.8])).toEqual({ goalId: "g_b", alignment: 1 });
    expect(bestGoal([{ id: "g_a", embedding: [-1, 0] }], [1, 0])).toEqual({ goalId: null, alignment: 0 });
    expect(bestGoal([{ id: "g_a", embedding: null }], [1, 0])).toEqual({ goalId: null, alignment: 0 });
    expect(bestGoal([{ id: "g_a", embedding: [1, 0] }], undefined)).toEqual({ goalId: null, alignment: 0 });
  });
});
