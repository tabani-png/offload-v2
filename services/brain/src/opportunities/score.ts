// Opportunity finder score (ARCHITECTURE section 6; old memory/opportunities.ts and usermodel/rank.ts):
//   score = weeklyHoursSaved x persistence x goalWeight x confidence / max(1, paybackWeeks) x declinePenalty
// goalWeight = 1 + 0.5 x alignment when the task advances a goal, 1 - 0.3 x alignment when it competes, else 1.
// An empty profile gives goalWeight 1 and no drain boost, so it changes no number.
// v2 fixes: paybackWeeks = setup hours / weekly saving from the fix estimate (was fixed at 1); confidence = fix-rule
// confidence x track record (proposition confidence never enters ranking); not_now lasts 4 weeks; leave_alone counts.
import { addWeeks } from "../records/dates.ts";
import { figure, r2, r3, type EvidenceRef, type Figure } from "../records/figure.ts";
import { DRAIN_KINDS, type WorkKind } from "../records/kinds.ts";
import type { WeekRecord } from "../records/week-record.ts";
import type { ReviewAnswer } from "../review/answers.ts";
import { cosine } from "../user-model/ledger.ts";

export const RESURFACE_RISE = 0.5;
export const DRAIN_BOOST = 0.1;
export const DRAIN_BOOST_WEEKS = 4;
export const NOT_NOW_WEEKS = 4;
export const PERSISTENCE_WEEKS = 8;
export const MAX_OPPORTUNITIES = 5;

export interface ScoreInput {
  weeklyHoursSaved: number;
  /** weeks present / weeks observed (last 8), 0..1, before the drain boost. */
  persistence: number;
  /** 0..1: fix-rule confidence x track record. */
  confidence: number;
  paybackWeeks: number;
  /** 0..1 */
  alignment: number;
  advances: boolean;
  competes?: boolean;
  declined: boolean;
  /** (minutes / baseline - 1) as a fraction; null without a baseline. */
  hoursVsBaseline: number | null;
  drainBoost: number;
}

export interface ScoreParts {
  weeklyHoursSaved: number;
  persistence: number;
  goalWeight: number;
  alignment: number;
  confidence: number;
  paybackWeeks: number;
  declinePenalty: number;
  drainBoost: number;
}

/** The fix designer's estimate for a task's top option (m5-04 port). */
export interface FixEstimate {
  taskKey: string;
  fixKind: string;
  weeklyHoursSaved: number;
  setupHours: number;
  /** 0..1, from the fix rules. */
  ruleConfidence: number;
  workKind: WorkKind;
}

export interface GoalVector {
  id: string;
  embedding: readonly number[] | null;
}

export interface RankInput {
  isoWeek: string;
  week: WeekRecord;
  /** Week records of the last 8 calendar weeks up to and including `isoWeek`. */
  recent: readonly WeekRecord[];
  estimates: readonly FixEstimate[];
  drains: readonly string[];
  goals: readonly GoalVector[];
  /** Task description embeddings by task key. */
  taskVectors: ReadonlyMap<string, readonly number[]>;
  answers: readonly ReviewAnswer[];
  /** This user's track record per fix kind, 0..1 (default 1). */
  trackRecord?: ReadonlyMap<string, number>;
  /** Task keys that compete with a goal (no producer yet). */
  competing?: ReadonlySet<string>;
}

export interface RankedOpportunity {
  task_key: string;
  name: string;
  rank: number;
  goal_id: string | null;
  score: Figure;
  factors: {
    weekly_hours_saved: Figure;
    persistence: Figure;
    goal_weight: Figure;
    alignment: Figure;
    confidence: Figure;
    payback_weeks: Figure;
    decline_penalty: Figure;
  };
}

const clamp01 = (x: number) => Math.min(1, Math.max(0, x));

export function opportunityScore(i: ScoreInput): { score: number; parts: ScoreParts } {
  const alignment = r3(clamp01(i.alignment));
  const goalWeight = r3(i.advances ? 1 + 0.5 * alignment : i.competes === true ? 1 - 0.3 * alignment : 1);
  const persistence = r3(clamp01(i.persistence + i.drainBoost));
  const declinePenalty = i.declined && !(i.hoursVsBaseline !== null && i.hoursVsBaseline >= RESURFACE_RISE) ? 0 : 1;
  const paybackWeeks = Math.max(1, i.paybackWeeks);
  const score = r3(((i.weeklyHoursSaved * persistence * goalWeight * i.confidence) / paybackWeeks) * declinePenalty);
  return { score, parts: { weeklyHoursSaved: i.weeklyHoursSaved, persistence, goalWeight, alignment, confidence: r3(i.confidence), paybackWeeks, declinePenalty, drainBoost: i.drainBoost } };
}

/** Setup hours over weekly saving; Infinity when nothing is saved. */
export function paybackWeeks(setupHours: number, weeklyHoursSaved: number): number {
  return weeklyHoursSaved > 0 ? r2(Math.max(0, setupHours) / weeklyHoursSaved) : Number.POSITIVE_INFINITY;
}

/** Best goal by cosine of goal and task embeddings, clamped to 0..1. */
export function bestGoal(goals: readonly GoalVector[], task: readonly number[] | undefined): { goalId: string | null; alignment: number } {
  let out: { goalId: string | null; alignment: number } = { goalId: null, alignment: 0 };
  if (task === undefined) return out;
  for (const g of goals) {
    if (g.embedding === null) continue;
    const c = r3(clamp01(cosine(g.embedding, task)));
    if (c > out.alignment) out = { goalId: g.id, alignment: c };
  }
  return out;
}

/** The latest answer about a task given on or before `isoWeek`. */
function latestFor(answers: readonly ReviewAnswer[], taskKey: string, isoWeek: string): ReviewAnswer | undefined {
  let out: ReviewAnswer | undefined;
  for (const a of answers) {
    if (a.subject_key !== taskKey || a.iso_week > isoWeek) continue;
    if (out === undefined || a.answered_at > out.answered_at || (a.answered_at === out.answered_at && a.iso_week > out.iso_week)) out = a;
  }
  return out;
}

/** Whether answers keep a task out of the ranking in `isoWeek` (before the 50% rise check). */
export function isDeclined(answers: readonly ReviewAnswer[], taskKey: string, isoWeek: string): boolean {
  const a = latestFor(answers, taskKey, isoWeek);
  if (a === undefined) return false;
  if (a.answer === "never" || a.answer === "leave_alone") return true;
  return a.answer === "not_now" && isoWeek < addWeeks(a.iso_week, NOT_NOW_WEEKS);
}

/** Top MAX_OPPORTUNITIES, every factor a Figure. */
export function rankOpportunities(input: RankInput): RankedOpportunity[] {
  const { isoWeek, week } = input;
  const oldest = addWeeks(isoWeek, -(PERSISTENCE_WEEKS - 1));
  const recent = [...new Map([...input.recent, week].filter((w) => w.iso_week >= oldest && w.iso_week <= isoWeek).map((w) => [w.iso_week, w])).values()];
  const observed = recent.length;
  const weekRefs: EvidenceRef[] = recent.map((w): EvidenceRef => ({ kind: "week_record", id: w.iso_week })).sort((a, b) => (a.id < b.id ? -1 : 1));
  const goalIds = new Set(input.goals.map((g) => g.id));
  const boostOn = week.weeks_observed <= DRAIN_BOOST_WEEKS;
  const out: Array<Omit<RankedOpportunity, "rank">> = [];
  for (const e of input.estimates) {
    const task = week.tasks.find((t) => t.task_key === e.taskKey);
    if (task === undefined || !(e.weeklyHoursSaved > 0)) continue;
    const estRef: EvidenceRef[] = [{ kind: "fix_estimate", id: e.taskKey }];
    const present = recent.filter((w) => w.tasks.some((t) => t.task_key === e.taskKey && t.minutes.value > 0)).length;
    const boost = boostOn && input.drains.some((d) => (DRAIN_KINDS[d] ?? []).includes(e.workKind)) ? DRAIN_BOOST : 0;
    const track = input.trackRecord?.get(e.fixKind) ?? 1;
    const confidence = r3(clamp01(e.ruleConfidence) * clamp01(track));
    const payback = paybackWeeks(e.setupHours, e.weeklyHoursSaved);
    const relevant = input.answers.filter((a) => a.subject_key === e.taskKey && a.iso_week <= isoWeek);
    const answerRefs: EvidenceRef[] = relevant.map((a) => ({ kind: "review_answer", id: `${a.iso_week}/${a.subject_key}` }));
    const named = latestFor(relevant.filter((a) => a.goal_id !== null && goalIds.has(a.goal_id)), e.taskKey, isoWeek);
    const goal = named !== undefined ? { goalId: named.goal_id, alignment: 1 } : bestGoal(input.goals, input.taskVectors.get(e.taskKey));
    const declined = isDeclined(relevant, e.taskKey, isoWeek);
    const competes = input.competing?.has(e.taskKey) === true;
    const s = opportunityScore({
      weeklyHoursSaved: e.weeklyHoursSaved, persistence: observed === 0 ? 0 : present / observed, confidence, paybackWeeks: payback,
      alignment: goal.alignment, advances: goal.alignment > 0 && !competes, competes, declined,
      hoursVsBaseline: task.vs_baseline === null ? null : task.vs_baseline.value / 100, drainBoost: boost,
    });
    const p = s.parts;
    const gwText = p.goalWeight === 1 ? "advances and competes with no goal: 1" : competes ? `1 - 0.3 x alignment ${p.alignment} = ${p.goalWeight}` : `1 + 0.5 x alignment ${p.alignment} = ${p.goalWeight}`;
    const alText = named !== undefined ? `a review answer names goal ${named.goal_id}: 1` : goal.goalId === null ? "no goal matches the task: 0" : `cosine of goal ${goal.goalId} and the task, clamped to 0..1 = ${p.alignment}`;
    const dpText = !declined ? "not declined in review: 1" : p.declinePenalty === 1 ? "declined, but its hours rose 50% or more over baseline: 1" : "declined in review: 0";
    out.push({
      task_key: e.taskKey, name: task.name, goal_id: goal.alignment > 0 ? goal.goalId : null,
      score: figure(s.score, "score", `${p.weeklyHoursSaved} x ${p.persistence} x ${p.goalWeight} x ${p.confidence} / max(1, ${r2(payback)}) x ${p.declinePenalty} = ${s.score}`, estRef),
      factors: {
        weekly_hours_saved: figure(e.weeklyHoursSaved, "hours_per_week", `top fix option (${e.fixKind}) from the fix rules: ${e.weeklyHoursSaved} h per week`, estRef),
        persistence: figure(p.persistence, "ratio", `present in ${present} of ${observed} weeks${boost > 0 ? ` + ${DRAIN_BOOST} drain boost (weeks 1 to ${DRAIN_BOOST_WEEKS})` : ""} = ${p.persistence}`, weekRefs),
        goal_weight: figure(p.goalWeight, "ratio", gwText, answerRefs),
        alignment: figure(p.alignment, "ratio", alText, answerRefs),
        confidence: figure(p.confidence, "ratio", `fix-rule confidence ${e.ruleConfidence} x track record ${track} = ${p.confidence}`, estRef),
        payback_weeks: figure(r2(payback), "weeks", `setup ${e.setupHours} h / ${e.weeklyHoursSaved} h saved per week = ${r2(payback)} weeks`, estRef),
        decline_penalty: figure(p.declinePenalty, "ratio", dpText, answerRefs),
      },
    });
  }
  out.sort((a, b) => b.score.value - a.score.value || (a.task_key < b.task_key ? -1 : 1));
  return out.slice(0, MAX_OPPORTUNITIES).map((o, i) => ({ ...o, rank: i + 1 }));
}
