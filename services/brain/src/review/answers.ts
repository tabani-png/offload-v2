// Review answers (old brain/src/memory/answers.ts): what the user said in the weekly review. Latest wins per week and
// subject. Feedback for ranking: `not_now` for 4 weeks; `never` and `leave_alone` until a later answer.

export const ANSWERS = ["keep", "not_now", "build", "never", "leave_alone", "yes", "no", "other_goal", "confirm_name", "dont_track", "undo"] as const;
export type Answer = (typeof ANSWERS)[number];
/** v1 asks about opportunities only; name and outcome questions come in M7. */
export const QUESTION_KINDS = ["opportunity"] as const;
export type QuestionKind = (typeof QUESTION_KINDS)[number];
export const OPPORTUNITY_ANSWERS: readonly Answer[] = ["keep", "not_now", "build", "never", "leave_alone", "other_goal"];
export const TASK_KEY_RE = /^k_[0-9a-f]{12}$/;
export const GOAL_ID_RE = /^g_[0-9a-f]{10}$/;

export interface ReviewAnswer {
  iso_week: string;
  subject_key: string;
  question_kind: QuestionKind;
  answer: Answer;
  goal_id: string | null;
  answered_at: string;
}

export type ParseResult =
  | { ok: true; answer: ReviewAnswer }
  | { ok: false; code: "schema_invalid" | "invalid_request"; message: string };

export function parseReviewAnswer(
  _body: unknown,
  _ctx: { activeGoalIds: readonly string[]; currentWeek: string; now: number },
): ParseResult {
  throw new Error("not implemented");
}
/** The latest answer per (iso_week, subject_key). */
export function latestAnswers(_answers: readonly ReviewAnswer[]): ReviewAnswer[] {
  throw new Error("not implemented");
}
