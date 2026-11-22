// Propositions (gum ideas) with bi-temporal merge (graphiti ideas). Carried from old s36 model.test.ts and
// longterm.test.ts; `sequence`, `precedes` and `supersedes` edges wait for M7.
import { describe, expect, test } from "bun:test";
import { mergePropositions } from "../../src/user-model/merge.ts";
import { confidenceOf, confidenceScore, decayOf } from "../../src/user-model/propose.ts";
import type { Proposition } from "../../src/user-model/types.ts";
import { updateMemberModel, type MemberUpdate } from "../../src/user-model/update.ts";
import { addDay, fixtureWeek, mondayNoonAfter, MONDAYS, taskOf } from "../fixtures/window.ts";

const WEEK2 = "2026-10-26";
const fx1 = fixtureWeek(MONDAYS[0]);
const fx2 = fixtureWeek(WEEK2, { seed: 7, without: ["calls"] });
const NOW1 = mondayNoonAfter(MONDAYS[0]);
const NOW2 = mondayNoonAfter(WEEK2);
const u1 = updateMemberModel(fx1.window, { ledger: [], propositions: [], analysedDays: [] }, NOW1);
const u2 = updateMemberModel(fx2.window, { ledger: u1.ledger, propositions: u1.propositions, analysedDays: u1.analysedDays }, NOW2);

const keyOf = (u: MemberUpdate, ref: string, fx = fx1) => u.keys.get(taskOf(fx, ref).id)!;
const find = (ps: readonly Proposition[], kind: string, key: string) => ps.filter((p) => p.kind === kind && p.evidence.subject.taskKey === key);
const outreach = () => find(u1.propositions, "repeats", keyOf(u1, "outreach"))[0]!;

const prop = (over: Partial<Proposition> & { perDay?: Record<string, { instances: number; minutes: number }> }): Proposition => {
  const perDay = over.perDay ?? { "2026-10-12": { instances: 100, minutes: 300 } };
  const { perDay: _p, ...rest } = over;
  return {
    id: "p_0000000000_v1", key: "repeats:k_aaaaaaaaaaaa", kind: "repeats", version: 1, revisionGroup: "repeats:k_aaaaaaaaaaaa",
    text: "x", confidence: 8, confidenceScore: 0.8, decay: 5, rate: 100,
    evidence: {
      instances: 0, days: 0, minutes: 0, dayList: [], perDay, sameness: 0.8, medianMinutes: 3, share: 0.2, lastSeenAt: 2, reasoning: "y",
      subject: { taskKey: "k_aaaaaaaaaaaa", taskKind: "email.outreach", name: "Outreach emails", appName: "Google Chrome", host: "mail.google.com" },
    },
    validAt: 1, invalidAt: null, recordedAt: 10, expiredAt: null, ...rest,
  };
};

describe("p43a propositions", () => {
  test("PROPOSE: a third-person 'repeatedly' proposition for the outreach task with the observed numbers", () => {
    const p = outreach();
    const t = taskOf(fx1, "outreach");
    expect(p.text.startsWith("They have been doing")).toBe(true);
    expect(p.text).toContain("repeatedly");
    expect(p.evidence.instances).toBe(t.instances.length);
    expect(p.evidence.days).toBe(5);
    expect(p.text).toContain(`${t.instances.length} times`);
    expect(p.evidence.reasoning.length).toBeGreaterThan(0);
  });

  test("PROPOSE: confidence is a computed 1..10 integer (gum scale) with a 0..1 score; strong evidence scores high", () => {
    for (const p of u1.propositions) {
      expect(Number.isInteger(p.confidence)).toBe(true);
      expect(p.confidence).toBeGreaterThanOrEqual(1);
      expect(p.confidence).toBeLessThanOrEqual(10);
      expect(p.confidenceScore).toBeGreaterThanOrEqual(0);
      expect(p.confidenceScore).toBeLessThanOrEqual(1);
      expect(Number.isInteger(p.decay)).toBe(true);
    }
    expect(outreach().confidence).toBeGreaterThanOrEqual(8);
    const rare = u1.propositions.filter((p) => p.kind === "repeats").sort((x, y) => x.evidence.instances - y.evidence.instances)[0]!;
    expect(rare.confidenceScore).toBeLessThan(outreach().confidenceScore);
    expect(confidenceScore({ days: 10, instances: 6, sameness: 0.5 })).toBe(0.771);
    expect(confidenceOf(0.771)).toBe(8);
    expect([decayOf({ days: 0 }), decayOf({ days: 7 }), decayOf({ days: 14 }), decayOf({ days: 40 })]).toEqual([1, 6, 10, 10]);
  });

  test("PROPOSE: bi-temporal fields (graphiti): valid_at = first seen, invalid_at and expired_at null while current", () => {
    const p = outreach();
    const t = taskOf(fx1, "outreach");
    expect(p.validAt).toBe(Math.min(...t.instances.map((i) => i.start)));
    expect(p.evidence.lastSeenAt).toBe(Math.max(...t.instances.map((i) => i.end)));
    expect(p.invalidAt).toBeNull();
    expect(p.expiredAt).toBeNull();
    expect(p.recordedAt).toBe(NOW1);
    expect(p.version).toBe(1);
    expect(p.id).toMatch(/^p_[0-9a-f]{10}_v1$/);
    expect(p.revisionGroup).toBe(p.key);
  });

  test("PROPOSE: a share-of-time proposition exists; no sequence propositions before M7", () => {
    expect(find(u1.propositions, "time_share", keyOf(u1, "outreach")).length).toBe(1);
    expect(u1.propositions.every((p) => p.kind === "repeats" || p.kind === "time_share")).toBe(true);
  });

  test("PROPOSE: deterministic for the same window", () => {
    const again = updateMemberModel(fx1.window, { ledger: [], propositions: [], analysedDays: [] }, NOW1);
    expect(JSON.stringify(again.propositions)).toBe(JSON.stringify(u1.propositions));
  });
});

describe("p43a long-term merge", () => {
  test("LONG-TERM: evidence from week 1 is kept after week 1 left the window (more than 7 distinct days)", () => {
    const key = keyOf(u1, "outreach");
    expect(keyOf(u2, "outreach", fx2)).toBe(key);
    const all = find(u2.propositions, "repeats", key);
    const days = new Set(all.flatMap((p) => p.evidence.dayList));
    expect(days.size).toBeGreaterThan(7);
    const cur = all.find((p) => p.invalidAt === null)!;
    expect(cur.evidence.dayList[0]! < WEEK2).toBe(true);
  });

  test("LONG-TERM: confidence does not drop for a pattern seen again", () => {
    const key = keyOf(u1, "outreach");
    const before = find(u1.propositions, "repeats", key)[0]!;
    const after = find(u2.propositions, "repeats", key).find((p) => p.invalidAt === null)!;
    expect(after.confidenceScore).toBeGreaterThanOrEqual(before.confidenceScore);
  });

  test("INVALIDATE: a pattern absent from the new window ends (invalid_at = last seen) and is expired, not deleted", () => {
    const key = keyOf(u1, "calls");
    const calls = find(u2.propositions, "repeats", key);
    expect(calls.length).toBe(1);
    const p = calls[0]!;
    expect(p.invalidAt).toBe(find(u1.propositions, "repeats", key)[0]!.evidence.lastSeenAt);
    expect(p.expiredAt).toBe(NOW2);
    expect(u2.propositions.length).toBeGreaterThanOrEqual(u1.propositions.length);
  });

  test("INVALIDATE: a gap with no analysed days ends nothing; 7 analysed days after the last sighting do", () => {
    const far = NOW1 + 60 * 86_400_000;
    const same = mergePropositions(u1.propositions, [], { now: far, analysedDays: u1.analysedDays });
    expect(same.every((p) => p.invalidAt === null)).toBe(true);
    // Slack is the only task seen on Sunday, the last analysed day.
    const last = u1.analysedDays[u1.analysedDays.length - 1]!;
    const slack = (ps: readonly Proposition[]) => find(ps, "repeats", keyOf(u1, "slack"))[0]!;
    expect(slack(u1.propositions).evidence.dayList.at(-1)).toBe(last);
    const six = Array.from({ length: 6 }, (_, i) => addDay(last, 30 + i));
    expect(slack(mergePropositions(u1.propositions, [], { now: far, analysedDays: [...u1.analysedDays, ...six] })).invalidAt).toBeNull();
    const ended = slack(mergePropositions(u1.propositions, [], { now: far, analysedDays: [...u1.analysedDays, ...six, addDay(last, 36)] }));
    expect(ended.invalidAt).toBe(ended.evidence.lastSeenAt);
    expect(ended.expiredAt).toBe(far);
  });

  test("MERGE: updating twice with the same window is idempotent", () => {
    const again = updateMemberModel(fx2.window, { ledger: u2.ledger, propositions: u2.propositions, analysedDays: u2.analysedDays }, NOW2 + 3_600_000);
    expect(JSON.stringify(again.propositions)).toBe(JSON.stringify(u2.propositions));
    expect(JSON.stringify(again.ledger)).toBe(JSON.stringify(u2.ledger));
    expect(again.analysedDays).toEqual(u2.analysedDays);
  });
});

describe("p43a contradiction (graphiti) and revision (gum)", () => {
  const days = ["2026-10-12", "2026-11-02"];

  test("SUPERSEDE: a rate that moved by more than half ends the old version and starts version 2 in the same revision group", () => {
    const old = prop({});
    const fresh = prop({ validAt: 1000, recordedAt: 3000, perDay: { "2026-11-02": { instances: 20, minutes: 60 } } });
    const m = mergePropositions([old], [fresh], { now: 3000, analysedDays: days });
    const versions = m.filter((p) => p.key === old.key).sort((x, y) => x.version - y.version);
    expect(versions.length).toBe(2);
    expect(versions[0]!.invalidAt).toBe(1000);
    expect(versions[0]!.expiredAt).toBe(3000);
    expect(versions[1]!.version).toBe(2);
    expect(versions[1]!.id).toMatch(/^p_[0-9a-f]{10}_v2$/);
    expect(versions[1]!.revisionGroup).toBe(versions[0]!.revisionGroup);
    expect(versions[1]!.invalidAt).toBeNull();
    expect(versions[1]!.recordedAt).toBe(3000);
    expect(versions[1]!.rate).toBe(20);
  });

  test("SUPERSEDE: invalid_at never precedes valid_at when windows overlap", () => {
    const old = prop({ validAt: 5000 });
    const fresh = prop({ validAt: 1000, perDay: { "2026-11-02": { instances: 20, minutes: 60 } } });
    const v1 = mergePropositions([old], [fresh], { now: 9000, analysedDays: days }).find((p) => p.version === 1)!;
    expect(v1.invalidAt).toBe(5000);
    expect(v1.invalidAt!).toBeGreaterThanOrEqual(v1.validAt);
  });

  test("SUPERSEDE: a rate change of exactly 50% revises; just over 50% starts a new version", () => {
    const old = prop({});
    const at50 = prop({ validAt: 1000, perDay: { "2026-11-02": { instances: 150, minutes: 450 } } });
    expect(mergePropositions([old], [at50], { now: 3000, analysedDays: days }).filter((p) => p.key === old.key).length).toBe(1);
    const over = prop({ validAt: 1000, perDay: { "2026-11-02": { instances: 151, minutes: 453 } } });
    expect(mergePropositions([old], [over], { now: 3000, analysedDays: days }).filter((p) => p.key === old.key).length).toBe(2);
  });

  test("REVISE: a similar rate merges into the same version, evidence days are unioned and counts recomputed", () => {
    const old = prop({});
    const fresh = prop({ validAt: 1000, perDay: { "2026-11-02": { instances: 90, minutes: 270 } } });
    fresh.evidence.lastSeenAt = 2000;
    const v = mergePropositions([old], [fresh], { now: 3000, analysedDays: days }).filter((p) => p.key === old.key);
    expect(v.length).toBe(1);
    expect(v[0]!.version).toBe(1);
    expect(v[0]!.evidence.dayList).toEqual(["2026-10-12", "2026-11-02"]);
    expect(v[0]!.evidence.instances).toBe(190);
    expect(v[0]!.rate).toBe(95);
    expect(v[0]!.validAt).toBe(1);
    expect(v[0]!.evidence.lastSeenAt).toBe(2000);
    expect(v[0]!.recordedAt).toBe(10);
  });
});
