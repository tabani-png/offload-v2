/**
 * @offload/brain
 * Cloud brain: understanding, user model, opportunity finder, fix designer.
 * See docs/ARCHITECTURE.md#5-cloud-brain-and-user-model and slices/p43a-user-model-core/DESIGN.md.
 */
export type { CompleteText, DayLabel, UnderstandingWindow, WindowInstance, WindowSpan, WindowTask } from "./user-model/ports.ts";
export { resolveTaskKeys, type LedgerEntry } from "./user-model/ledger.ts";
export { updateMemberModel, type MemberState, type MemberUpdate } from "./user-model/update.ts";
export type { Proposition } from "./user-model/types.ts";
export { buildDayRecords, type DayRecord, type Episode } from "./records/day-record.ts";
export { buildWeekRecord, type WeekRecord } from "./records/week-record.ts";
export { buildRollup, theilSen, type RollupRecord } from "./records/rollup.ts";
export { checkNarrative, weekSentence, writeWeekSentence } from "./records/narrative.ts";
export { figure, type Figure } from "./records/figure.ts";
export { rankOpportunities, opportunityScore, type FixEstimate, type RankedOpportunity } from "./opportunities/score.ts";
export { applyProfilePatch, defaultProfile, userContextOf, type Goal, type Profile } from "./profile/profile.ts";
export { parseReviewAnswer, type ReviewAnswer } from "./review/answers.ts";
export { buildWeekReview, type WeekReview } from "./review/week-review.ts";
export { userContextBlock, type UserContext } from "./understanding/context.ts";
// Understanding (m5-01): the producer of UnderstandingWindow. m5-04 and m1-06 use these.
export * from "./understanding/index.ts";
