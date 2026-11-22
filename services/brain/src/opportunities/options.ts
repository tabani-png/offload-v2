// An option from a bare FixEstimate (slice m5-04): `estimateFor` callers give numbers without an option. Storing it as
// option 1 keeps every ranked finder opportunity with at least one option row. Numbers are the estimate's, unchanged.
import { figure, type EvidenceRef } from "../records/figure.ts";
import { LEAVE_ALONE_BELOW_HOURS } from "./rules.ts";
import { paybackWeeks, type FixEstimate } from "./score.ts";
import type { FixOption, ProposedFixKind } from "./types.ts";

const KINDS: readonly ProposedFixKind[] = ["api_integration", "agent_workflow", "scheduled_routine", "script", "browser_automation", "setup_change"];

export function bareOption(e: FixEstimate, isoWeek: string): FixOption {
  const refs: EvidenceRef[] = [{ kind: "fix_estimate", id: e.taskKey }, { kind: "week_record", id: isoWeek }];
  const kind = (KINDS as readonly string[]).includes(e.fixKind) ? (e.fixKind as ProposedFixKind) : "script";
  const payback = e.weeklyHoursSaved > 0 ? paybackWeeks(e.setupHours, e.weeklyHoursSaved) : 0;
  return {
    option_no: 1, kind, rule: "estimate", recommended: e.weeklyHoursSaved >= LEAVE_ALONE_BELOW_HOURS,
    title: `A ${kind.replaceAll("_", " ")} for this task`, detail: "", steps: [],
    figures: {
      weekly_hours_saved: figure(e.weeklyHoursSaved, "hours_per_week", `estimate given for ${kind}: ${e.weeklyHoursSaved} h per week`, refs),
      setup_hours: figure(e.setupHours, "hours", `estimate given for ${kind}: ${e.setupHours} h`, refs),
      payback_weeks: figure(payback, "weeks", `setup ${e.setupHours} h / ${e.weeklyHoursSaved} h saved per week = ${payback} weeks`, refs),
      confidence: figure(e.ruleConfidence, "ratio", `estimate given for ${kind}: ${e.ruleConfidence}`, refs),
    },
  };
}
