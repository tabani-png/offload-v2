// An option from a bare FixEstimate (slice m5-04): `estimateFor` callers give numbers without an option. Storing it as
// option 1 keeps every ranked finder opportunity with at least one option row. Numbers are the estimate's, unchanged.
// A kind `fixes` cannot store (`leave_alone` is an answer, not an option; anything unknown) or an estimate that saves
// nothing gives no option, so no option carries false arithmetic (review 1 finding 4).
import { figure, type EvidenceRef } from "../records/figure.ts";
import { LEAVE_ALONE_BELOW_HOURS } from "./rules.ts";
import { paybackWeeks, type FixEstimate } from "./score.ts";
import type { FixOption, StoredFixKind } from "./types.ts";

const WORDS: Readonly<Record<StoredFixKind, string>> = {
  api_integration: "an integration",
  agent_workflow: "an agent workflow",
  scheduled_routine: "a scheduled routine",
  script: "a script or Shortcut",
  browser_automation: "browser automation",
  setup_change: "a setup change",
  small_app: "a small app",
  remove_step: "dropping a step",
};

export function bareOption(e: FixEstimate, isoWeek: string): FixOption | null {
  if (!Object.hasOwn(WORDS, e.fixKind) || !(e.weeklyHoursSaved > 0)) return null;
  const kind = e.fixKind as StoredFixKind;
  const refs: EvidenceRef[] = [{ kind: "fix_estimate", id: e.taskKey }, { kind: "week_record", id: isoWeek }];
  const payback = paybackWeeks(e.setupHours, e.weeklyHoursSaved);
  return {
    option_no: 1, kind, rule: "estimate", recommended: e.weeklyHoursSaved >= LEAVE_ALONE_BELOW_HOURS,
    title: `Proposed fix: ${WORDS[kind]}`, detail: "", steps: [],
    figures: {
      weekly_hours_saved: figure(e.weeklyHoursSaved, "hours_per_week", `estimate given for ${kind}: ${e.weeklyHoursSaved} h per week`, refs),
      setup_hours: figure(e.setupHours, "hours", `estimate given for ${kind}: ${e.setupHours} h`, refs),
      payback_weeks: figure(payback, "weeks", `setup ${e.setupHours} h / ${e.weeklyHoursSaved} h saved per week = ${payback} weeks`, refs),
      confidence: figure(e.ruleConfidence, "ratio", `estimate given for ${kind}: ${e.ruleConfidence}`, refs),
    },
  };
}
