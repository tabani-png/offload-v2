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
// Fix rules (m5-04): task evidence -> one to three proposed fix options with estimates; m1-06 passes fixRules() to
// the understanding job, m5-05 reads stored opportunities with listOpportunityViews / getOpportunityView.
export * from "./opportunities/types.ts";
export { buildTaskEvidence, CADENCE_WEEKS, type EvidenceInput } from "./opportunities/evidence.ts";
export { ADAPTER_ORDER, LAUNCH_CATALOG, resolveConnector, type CatalogApp } from "./opportunities/connectors.ts";
export { FIX_KIND_TABLE, FIX_RULES, fixRules, LEAVE_ALONE_BELOW_HOURS, MIN_INSTANCES, type FixProposal, type FixRule, type FixRules } from "./opportunities/rules.ts";
export { runMemberUpdate, type MemberUpdateInput, type MemberUpdateResult } from "./store/job.ts";
export { getOpportunityView, listOpportunityViews, type OpportunityView } from "./store/repository.ts";
export { applyProfilePatch, defaultProfile, userContextOf, type Goal, type Profile } from "./profile/profile.ts";
export { parseReviewAnswer, type ReviewAnswer } from "./review/answers.ts";
export { buildWeekReview, type WeekReview } from "./review/week-review.ts";
export { userContextBlock, type UserContext } from "./understanding/context.ts";
// Understanding (m5-01): the producer of UnderstandingWindow. m5-04 and m1-06 use these.
export * from "./understanding/index.ts";
