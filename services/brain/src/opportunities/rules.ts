// Fix rules (slice m5-04, SPEC Design notes 2, 4 and 5): rule kinds that map task evidence to proposed fix options.
import type { FixEstimate } from "./score.ts";
import type { FixOption, ProposedFixKind, RuleKind, TaskEvidence, TenantCatalog } from "./types.ts";

export interface KindRow {
  share: number;
  reviewMinutes: number;
  setupBase: number;
  setupPerStep: number;
  confidence: number;
}

export const FIX_KIND_TABLE: Readonly<Record<ProposedFixKind, KindRow>> = {
  api_integration: { share: 0.8, reviewMinutes: 0.5, setupBase: 2, setupPerStep: 1, confidence: 0.7 },
  agent_workflow: { share: 0.7, reviewMinutes: 1, setupBase: 3, setupPerStep: 1, confidence: 0.6 },
  scheduled_routine: { share: 0.85, reviewMinutes: 1, setupBase: 2, setupPerStep: 0.5, confidence: 0.75 },
  script: { share: 0.5, reviewMinutes: 0.5, setupBase: 1.5, setupPerStep: 0.5, confidence: 0.55 },
  browser_automation: { share: 0.6, reviewMinutes: 1, setupBase: 3, setupPerStep: 1, confidence: 0.5 },
  setup_change: { share: 0.3, reviewMinutes: 0, setupBase: 0.5, setupPerStep: 0, confidence: 0.6 },
};

export const MIN_INSTANCES = 3;
export const LEAVE_ALONE_BELOW_HOURS = 0.5;

export interface FixRule {
  kind: RuleKind;
  matches(e: TaskEvidence): boolean;
  options(e: TaskEvidence): ProposedFixKind[];
}

export const FIX_RULES: readonly FixRule[] = [];

export interface FixProposal {
  task_key: string;
  rule: RuleKind;
  /** The best option saves under LEAVE_ALONE_BELOW_HOURS a week: "leave it alone" comes first, none is recommended. */
  leave_alone_first: boolean;
  options: FixOption[];
  /** Option 1's numbers, for rankOpportunities. */
  estimate: FixEstimate;
}

export interface FixRules {
  propose(e: TaskEvidence): FixProposal | null;
}

export function fixRules(_opts: { catalog?: TenantCatalog } = {}): FixRules {
  throw new Error("not implemented");
}
