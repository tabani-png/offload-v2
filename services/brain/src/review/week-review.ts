// GET /v1/review/week payload: one sentence, tiles (Figures), goals, up to 4 questions about open opportunities.
import { weekSentence } from "../records/narrative.ts";
import type { Figure } from "../records/figure.ts";
import type { WeekRecord } from "../records/week-record.ts";
import type { Goal } from "../profile/profile.ts";
import { latestAnswers, OPPORTUNITY_ANSWERS, type Answer, type ReviewAnswer } from "./answers.ts";

export const MAX_QUESTIONS = 4;

export interface ReviewOpportunity {
  task_key: string;
  name: string;
  rank: number;
  state: string;
  /** A declined task can still rank with score 0; it is not asked about. */
  score?: number;
}

export interface WeekReview {
  iso_week: string;
  sentence: string;
  tiles: Figure[];
  goals: Array<{ id: string; text: string }>;
  questions: Array<{
    subject_key: string;
    question_kind: "opportunity";
    name: string;
    answers: Answer[];
    answered: Answer | null;
  }>;
}

export function buildWeekReview(input: {
  week: WeekRecord;
  goals: readonly Goal[];
  opportunities: readonly ReviewOpportunity[];
  answers: readonly ReviewAnswer[];
}): WeekReview {
  const { week } = input;
  const latest = latestAnswers(input.answers.filter((a) => a.iso_week === week.iso_week));
  return {
    iso_week: week.iso_week,
    sentence: week.narrative ?? weekSentence(week),
    tiles: [week.hours.total, week.focus.minutes, week.focus.meeting_hours, week.focus.switches_per_active_hour],
    goals: input.goals.filter((g) => g.archived_at === null).map((g) => ({ id: g.id, text: g.text })),
    questions: input.opportunities
      .filter((o) => o.state === "open" && (o.score ?? 1) > 0)
      .sort((a, b) => a.rank - b.rank)
      .slice(0, MAX_QUESTIONS)
      .map((o) => ({
        subject_key: o.task_key, question_kind: "opportunity" as const, name: o.name, answers: [...OPPORTUNITY_ANSWERS],
        answered: latest.find((a) => a.subject_key === o.task_key)?.answer ?? null,
      })),
  };
}
