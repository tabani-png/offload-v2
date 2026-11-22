// Fix rules (slice m5-04, SPEC Design notes 2 and 5; ARCHITECTURE sections 6 and 7): a table of rule kinds that maps
// a task's evidence to one to three proposed fix options. Kinds, steps, numbers and order come from code; no model.
import type { WorkKind } from "../records/kinds.ts";
import { resolveConnector } from "./connectors.ts";
import { CLOUD_KINDS, estimateOption } from "./estimate.ts";
import type { FixEstimate } from "./score.ts";
import type { FixOption, FixStep, ProposedFixKind, RuleKind, System, TaskEvidence, TenantCatalog } from "./types.ts";

export { FIX_KIND_TABLE, type KindRow } from "./estimate.ts";

/** A task seen fewer times than this in the week, without a cadence, gets no fix. */
export const MIN_INSTANCES = 3;
/** Below this best saving per week, "leave it alone" comes first (ARCHITECTURE section 7). */
export const LEAVE_ALONE_BELOW_HOURS = 0.5;
export const MAX_OPTIONS = 3;
/** Work the rules never propose a fix for. */
const NO_FIX: ReadonlySet<WorkKind> = new Set(["code", "meeting", "chat"]);

export interface FixRule {
  kind: RuleKind;
  matches(e: TaskEvidence): boolean;
  /** Fix kinds to try, in the rule's order. */
  options(e: TaskEvidence): ProposedFixKind[];
}

const isEmail = (s: System) => s.work_kind === "email";
// Browser automation runs in the user's browser: it is offered only when every step is a web app (review 1 finding 2).
const allWeb = (e: TaskEvidence) => e.systems.every((s) => s.surface === "web");
const hasDesktop = (e: TaskEvidence) => e.systems.some((s) => s.surface === "desktop");
const when = <T>(c: boolean, x: T): T[] => (c ? [x] : []);

export const FIX_RULES: readonly FixRule[] = [
  {
    kind: "report_assembly",
    matches: (e) => e.cadence !== null && e.systems.length >= 2 && e.systems.some((s) => s.work_kind === "sheet" || s.work_kind === "docs"),
    options: () => ["scheduled_routine", "script"],
  },
  {
    kind: "email_triage",
    matches: (e) => e.systems.every(isEmail) && e.instances >= 5 && e.median_minutes <= 10,
    options: () => ["setup_change", "agent_workflow"],
  },
  {
    kind: "email_to_records",
    matches: (e) => e.systems.some(isEmail) && e.systems.some((s) => !isEmail(s)),
    options: (e) => ["agent_workflow", "api_integration", ...when(allWeb(e), "browser_automation" as const), ...when(hasDesktop(e), "script" as const)],
  },
  {
    kind: "app_to_app_copy",
    matches: (e) => e.systems.filter((s) => !isEmail(s)).length >= 2,
    options: (e) => ["api_integration", ...when(allWeb(e), "browser_automation" as const), ...when(hasDesktop(e), "script" as const)],
  },
  {
    kind: "single_app_entry",
    matches: (e) => e.systems.length === 1 && (["sheet", "docs", "browse", "other"] as WorkKind[]).includes(e.systems[0]!.work_kind),
    options: (e) => [e.systems[0]!.surface === "web" ? "browser_automation" : "script"],
  },
];

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

/** Each step of a fix kind, in system id order: cloud kinds and scripts resolve connectors; browser automation drives the web apps on
 * the device; a setup change is applied by the user on the device. */
export function stepsFor(kind: ProposedFixKind, systems: readonly System[], catalog?: TenantCatalog): FixStep[] {
  const sorted = [...systems].sort((a, b) => (a.id < b.id ? -1 : a.id > b.id ? 1 : 0));
  return sorted.map((s): FixStep => {
    const c = resolveConnector(s, catalog);
    if (kind === "setup_change") return { system: s.id, surface: s.surface, provider: c.provider, label: c.label, adapter: null, runs_on: "device" };
    if (kind === "browser_automation") return { system: s.id, surface: s.surface, provider: c.provider, label: c.label, adapter: s.surface === "web" ? "browser" : null, runs_on: "device" };
    return { system: s.id, surface: s.surface, ...c };
  });
}

const WEEKDAYS = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"];
// Plain mechanics in option text (PRODUCT copy rules): the adapter itself stays in `steps`.
const ADAPTER_WORDS = { mcp: "through a connector", composio: "through a connector", openapi: "through a connector", browser: "in your browser, on your Mac" } as const;
const hh = (h: number) => `${String(h).padStart(2, "0")}:00`;

function joinLabels(labels: readonly string[]): string {
  const u = [...new Set(labels)];
  return u.length <= 1 ? (u[0] ?? "") : `${u.slice(0, -1).join(", ")} and ${u[u.length - 1]}`;
}

function titleOf(kind: ProposedFixKind, e: TaskEvidence, steps: readonly FixStep[]): string {
  const labels = joinLabels(steps.map((s) => s.label));
  switch (kind) {
    case "api_integration": return `Connect ${labels} with an integration`;
    case "agent_workflow": return `An agent prepares the work in ${labels} and you approve it`;
    case "scheduled_routine": {
      const c = e.cadence;
      const at = c === null ? "on a schedule" : c.kind === "daily" ? `every day at ${hh(c.hour)}` : `every ${WEEKDAYS[c.weekday ?? 0]} at ${hh(c.hour)}`;
      return `A scheduled routine does it ${at}`;
    }
    case "script": return `A Shortcut or script does the steps in ${labels}`;
    case "browser_automation": return `Browser automation does the steps in ${labels} while you watch`;
    case "setup_change": return `Rules in ${labels} handle it for you`;
  }
}

function detailOf(e: TaskEvidence, steps: readonly FixStep[]): string {
  const words = steps.map((s) => `${s.label} (${s.adapter === null ? "on your Mac" : ADAPTER_WORDS[s.adapter]})`).join(", ");
  return `Seen ${e.instances} time${e.instances === 1 ? "" : "s"} this week (${e.minutes} min). Steps: ${words}.`;
}

/** The work kind the drain boost matches: the first of these the task touches. */
const KIND_PRIORITY: readonly WorkKind[] = ["email", "sheet", "docs", "chat", "browse", "code", "meeting", "other"];

/** The value options are ordered by: the score's own factors (saving x confidence / max(1, payback)). */
export const optionValue = (o: FixOption): number => (o.figures.weekly_hours_saved.value * o.figures.confidence.value) / Math.max(1, o.figures.payback_weeks.value);

export function fixRules(opts: { catalog?: TenantCatalog } = {}): FixRules {
  return {
    propose(e: TaskEvidence): FixProposal | null {
      if (e.systems.length === 0 || e.systems.every((s) => NO_FIX.has(s.work_kind))) return null;
      if (e.instances < MIN_INSTANCES && e.cadence === null) return null;
      const rule = FIX_RULES.find((r) => r.matches(e));
      if (rule === undefined) return null;
      const candidates: Array<{ option: FixOption; order: number }> = [];
      for (const [order, kind] of rule.options(e).entries()) {
        const steps = stepsFor(kind, e.systems, opts.catalog);
        // A cloud kind with no connector on any step would be browser automation under another name.
        if (CLOUD_KINDS.has(kind) && !steps.some((s) => s.adapter !== null && s.adapter !== "browser")) continue;
        const figures = estimateOption(kind, e, steps);
        if (figures === null) continue;
        candidates.push({ order, option: { option_no: 0, kind, rule: rule.kind, recommended: false, title: titleOf(kind, e, steps), detail: detailOf(e, steps), steps, figures } });
      }
      if (candidates.length === 0) return null;
      // Options that save at least LEAVE_ALONE_BELOW_HOURS come first, so a recommended option always clears it
      // (review 1 finding 3); within each group by value, then the rule's order.
      const clears = (o: FixOption) => (o.figures.weekly_hours_saved.value >= LEAVE_ALONE_BELOW_HOURS ? 1 : 0);
      candidates.sort((a, b) => clears(b.option) - clears(a.option) || optionValue(b.option) - optionValue(a.option) || a.order - b.order);
      const kept = candidates.slice(0, MAX_OPTIONS).map((c) => c.option);
      const leaveAloneFirst = Math.max(...kept.map((o) => o.figures.weekly_hours_saved.value)) < LEAVE_ALONE_BELOW_HOURS;
      const options = kept.map((o, i): FixOption => ({ ...o, option_no: i + 1, recommended: i === 0 && !leaveAloneFirst }));
      const top = options[0]!;
      const workKind = KIND_PRIORITY.find((k) => e.systems.some((s) => s.work_kind === k)) ?? "other";
      return {
        task_key: e.task_key, rule: rule.kind, leave_alone_first: leaveAloneFirst, options,
        estimate: {
          taskKey: e.task_key, fixKind: top.kind, weeklyHoursSaved: top.figures.weekly_hours_saved.value, setupHours: top.figures.setup_hours.value,
          ruleConfidence: top.figures.confidence.value, workKind, option: top,
        },
      };
    },
  };
}
