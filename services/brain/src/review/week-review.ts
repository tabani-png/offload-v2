// GET /v1/review/week payload: one sentence, tiles (Figures), goals, up to 4 questions.
import type { Figure } from "../records/figure.ts";
import type { WeekRecord } from "../records/week-record.ts";
import type { Goal } from "../profile/profile.ts";
import type { Answer, ReviewAnswer } from "./answers.ts";

export const MAX_QUESTIONS = 4;

export interface ReviewOpportunity {
  task_key: string;
  name: string;
  rank: number;
  state: string;
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

export function buildWeekReview(_input: {
  week: WeekRecord;
  goals: readonly Goal[];
  opportunities: readonly ReviewOpportunity[];
  answers: readonly ReviewAnswer[];
}): WeekReview {
  throw new Error("not implemented");
}
