// Opportunity finder score (ARCHITECTURE section 6; old memory/opportunities.ts and usermodel/rank.ts):
//   score = weeklyHoursSaved x persistence x goalWeight x confidence / max(1, paybackWeeks) x declinePenalty
// goalWeight = 1 + 0.5 x alignment when the task advances a goal, 1 - 0.3 x alignment when it competes, else 1.
// An empty profile gives goalWeight 1 and no drain boost, so it changes no number.
import type { Figure } from "../records/figure.ts";
import type { WorkKind } from "../records/kinds.ts";
import type { WeekRecord } from "../records/week-record.ts";
import type { ReviewAnswer } from "../review/answers.ts";

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

export function opportunityScore(_i: ScoreInput): { score: number; parts: ScoreParts } {
  throw new Error("not implemented");
}
/** Setup hours over weekly saving; Infinity when nothing is saved. */
export function paybackWeeks(_setupHours: number, _weeklyHoursSaved: number): number {
  throw new Error("not implemented");
}
/** Best goal by cosine of goal and task embeddings, clamped to 0..1. */
export function bestGoal(_goals: readonly GoalVector[], _task: readonly number[] | undefined): { goalId: string | null; alignment: number } {
  throw new Error("not implemented");
}
/** Whether answers keep a task out of the ranking in `isoWeek` (before the 50% rise check). */
export function isDeclined(_answers: readonly ReviewAnswer[], _taskKey: string, _isoWeek: string): boolean {
  throw new Error("not implemented");
}
/** Top MAX_OPPORTUNITIES, every factor a Figure. */
export function rankOpportunities(_input: RankInput): RankedOpportunity[] {
  throw new Error("not implemented");
}
