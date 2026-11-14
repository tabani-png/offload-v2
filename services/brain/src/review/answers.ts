// Review answers (old brain/src/memory/answers.ts): what the user said in the weekly review. Latest wins per week and
// subject. Feedback for ranking: `not_now` for 4 weeks; `never` and `leave_alone` until a later answer.
import { isIsoWeek } from "../records/dates.ts";

export const ANSWERS = ["keep", "not_now", "build", "never", "leave_alone", "yes", "no", "other_goal", "confirm_name", "dont_track", "undo"] as const;
export type Answer = (typeof ANSWERS)[number];
/** v1 asks about opportunities only; name and outcome questions come in M7. */
export const QUESTION_KINDS = ["opportunity"] as const;
export type QuestionKind = (typeof QUESTION_KINDS)[number];
export const OPPORTUNITY_ANSWERS: readonly Answer[] = ["keep", "not_now", "build", "never", "leave_alone", "other_goal"];
/** Answers that may name a goal ("this is for goal N"). */
export const GOAL_ANSWERS: readonly Answer[] = ["keep", "build", "other_goal"];
export const TASK_KEY_RE = /^k_[0-9a-f]{12}$/;
export const GOAL_ID_RE = /^g_[0-9a-f]{10}$/;
const FIELDS = ["iso_week", "subject_key", "question_kind", "answer", "goal_id"];

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

const schema = (message: string): ParseResult => ({ ok: false, code: "schema_invalid", message });

export function parseReviewAnswer(body: unknown, ctx: { activeGoalIds: readonly string[]; currentWeek: string; now: number }): ParseResult {
  if (typeof body !== "object" || body === null || Array.isArray(body)) return schema("the body must be a JSON object");
  const b = body as Record<string, unknown>;
  for (const k of Object.keys(b)) if (!FIELDS.includes(k)) return schema(`${k} is not a field`);
  const week = b["iso_week"];
  if (typeof week !== "string" || !isIsoWeek(week)) return schema("iso_week must be YYYY-Www");
  const kind = b["question_kind"];
  if (!(QUESTION_KINDS as readonly unknown[]).includes(kind)) return schema(`question_kind must be one of ${QUESTION_KINDS.join(", ")}`);
  const subject = b["subject_key"];
  if (typeof subject !== "string" || !TASK_KEY_RE.test(subject)) return schema("subject_key must be a task key (k_ + 12 hex)");
  const answer = b["answer"];
  if (!OPPORTUNITY_ANSWERS.includes(answer as Answer)) return schema(`answer must be one of ${OPPORTUNITY_ANSWERS.join(", ")}`);
  const goal = b["goal_id"] ?? null;
  if (goal !== null && (typeof goal !== "string" || !GOAL_ID_RE.test(goal))) return schema("goal_id must be a goal id (g_ + 10 hex)");
  if (answer === "other_goal" && goal === null) return schema("other_goal needs goal_id");
  if (goal !== null && !GOAL_ANSWERS.includes(answer as Answer)) return schema(`goal_id goes with ${GOAL_ANSWERS.join(", ")} only`);
  if (week > ctx.currentWeek) return { ok: false, code: "invalid_request", message: "a future week cannot be answered" };
  if (goal !== null && !ctx.activeGoalIds.includes(goal)) return { ok: false, code: "invalid_request", message: "goal_id is not one of your goals" };
  return { ok: true, answer: { iso_week: week, subject_key: subject, question_kind: "opportunity", answer: answer as Answer, goal_id: goal as string | null, answered_at: new Date(ctx.now).toISOString() } };
}

/** The latest answer per (iso_week, subject_key), sorted by week and subject. */
export function latestAnswers(answers: readonly ReviewAnswer[]): ReviewAnswer[] {
  const out = new Map<string, ReviewAnswer>();
  for (const a of answers) {
    const k = `${a.iso_week}|${a.subject_key}`;
    const cur = out.get(k);
    if (cur === undefined || a.answered_at >= cur.answered_at) out.set(k, a);
  }
  return [...out.values()].sort((a, b) => (a.iso_week < b.iso_week ? -1 : a.iso_week > b.iso_week ? 1 : a.subject_key < b.subject_key ? -1 : 1));
}
