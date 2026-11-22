// Fix rules (slice m5-04, ARCHITECTURE sections 6 and 7): the shapes between task evidence, the rule table, the
// connector resolution of ADR 0033 and the proposed fix options. Every number is a Figure computed in code (ADR 0003).
import type { Figure } from "../records/figure.ts";
import type { WorkKind } from "../records/kinds.ts";

/** Fix kinds the rules propose (GLOSSARY "Fix kind"; `small_app`, `remove_step` and `leave_alone` are not proposed). */
export type ProposedFixKind = "api_integration" | "agent_workflow" | "scheduled_routine" | "script" | "browser_automation" | "setup_change";

/** Rule kinds of the fix rules table, in match order. */
export type RuleKind = "report_assembly" | "email_triage" | "email_to_records" | "app_to_app_copy" | "single_app_entry";

/** Connector adapters in ADR 0033's resolution order. */
export type Adapter = "mcp" | "composio" | "openapi" | "browser";

/** One system a task touches: a web app (bare host) or a desktop app (bundle id). */
export interface System {
  /** The host for `web`, the bundle id for `desktop`. */
  id: string;
  surface: "web" | "desktop";
  work_kind: WorkKind;
}

/** A regular start time: `daily` (weekday null) or `weekly` (weekday 0 = Monday ... 6 = Sunday), member timezone. */
export interface Cadence {
  kind: "daily" | "weekly";
  weekday: number | null;
  /** Median start hour, 0..23. */
  hour: number;
}

/** What the fix rules read about one task of one week. Counts, bundle ids, bare hosts and episode ids only. */
export interface TaskEvidence {
  task_key: string;
  /** Masked task name from the week record. */
  name: string;
  iso_week: string;
  /** Week record values (the Figures the score uses). */
  minutes: number;
  instances: number;
  median_minutes: number;
  /** Distinct days of the week with an instance. */
  days: number;
  systems: System[];
  cadence: Cadence | null;
  /** This week's task-instance episodes (evidence). */
  episode_ids: string[];
}

/** The connector chosen for one step. `adapter: null` = no connector: the step runs on the device. */
export interface ConnectorChoice {
  provider: string | null;
  label: string;
  adapter: Adapter | null;
  runs_on: "cloud" | "device";
}

export interface FixStep extends ConnectorChoice {
  system: string;
  surface: "web" | "desktop";
}

/** A tenant's view of the catalog (m2-02 verified entries later); the default allows every listed method. */
export interface TenantCatalog {
  allows(provider: string, adapter: Adapter): boolean;
}

export interface FixOptionFigures {
  weekly_hours_saved: Figure;
  setup_hours: Figure;
  payback_weeks: Figure;
  confidence: Figure;
}

export interface FixOption {
  /** 1..3 */
  option_no: number;
  kind: ProposedFixKind;
  rule: RuleKind;
  recommended: boolean;
  /** Code template from masked words only. */
  title: string;
  detail: string;
  steps: FixStep[];
  figures: FixOptionFigures;
}
