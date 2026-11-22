// The estimate of one proposed fix option (slice m5-04, SPEC Design note 4): weekly hours saved, setup hours,
// payback and confidence, each a Figure with its arithmetic (ADR 0003). Constants come from FIX_KIND_TABLE.
import { figure, r2, r3, type EvidenceRef } from "../records/figure.ts";
import { paybackWeeks } from "./score.ts";
import type { FixOptionFigures, FixStep, ProposedFixKind, TaskEvidence } from "./types.ts";

export interface KindRow {
  /** Share of the task's time the fix takes over. */
  share: number;
  /** Minutes a person still spends per instance (reviewing, approving). */
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

/** Kinds that run in the cloud runtime through connectors (ARCHITECTURE section 12). */
export const CLOUD_KINDS: ReadonlySet<ProposedFixKind> = new Set(["api_integration", "agent_workflow", "scheduled_routine"]);

/** In a cloud kind, a step reached through the browser or only on the device costs setup and confidence. */
export const BROWSER_STEP = { setupHours: 1, confidence: 0.85 } as const;
export const DEVICE_STEP = { setupHours: 0.5, confidence: 0.9 } as const;
/** Evidence factors: fewer than 5 instances, or a single day, without a cadence. */
export const FEW_INSTANCES = { below: 5, factor: 0.85 } as const;
export const ONE_DAY = { below: 2, factor: 0.85 } as const;

const clamp01 = (x: number) => Math.min(1, Math.max(0, x));

/** The option's figures, or null when it saves nothing. */
export function estimateOption(kind: ProposedFixKind, e: TaskEvidence, steps: readonly FixStep[]): FixOptionFigures | null {
  const row = FIX_KIND_TABLE[kind];
  const refs: EvidenceRef[] = [{ kind: "week_record", id: e.iso_week }, ...e.episode_ids.map((id): EvidenceRef => ({ kind: "episode", id }))];
  const saved = r2(Math.max(0, e.minutes * row.share - e.instances * row.reviewMinutes) / 60);
  if (!(saved > 0)) return null;
  const cloud = CLOUD_KINDS.has(kind);
  const browser = cloud ? steps.filter((s) => s.adapter === "browser").length : 0;
  const device = cloud ? steps.filter((s) => s.adapter === null).length : 0;

  const setup = r2(row.setupBase + row.setupPerStep * steps.length + BROWSER_STEP.setupHours * browser + DEVICE_STEP.setupHours * device);
  const setupTerms = [`base ${row.setupBase}`, `${row.setupPerStep} x ${steps.length} steps`];
  if (browser > 0) setupTerms.push(`${BROWSER_STEP.setupHours} x ${browser} browser steps`);
  if (device > 0) setupTerms.push(`${DEVICE_STEP.setupHours} x ${device} device steps`);

  const fi = e.instances >= FEW_INSTANCES.below || e.cadence !== null ? 1 : FEW_INSTANCES.factor;
  const fd = e.days >= ONE_DAY.below || e.cadence !== null ? 1 : ONE_DAY.factor;
  const conf = r3(clamp01(row.confidence * fi * fd * BROWSER_STEP.confidence ** browser * DEVICE_STEP.confidence ** device));
  const confTerms = [`${kind} ${row.confidence}`, `instances ${fi}`, `days ${fd}`];
  for (let i = 0; i < browser; i++) confTerms.push(`browser step ${BROWSER_STEP.confidence}`);
  for (let i = 0; i < device; i++) confTerms.push(`device step ${DEVICE_STEP.confidence}`);

  const payback = paybackWeeks(setup, saved);
  return {
    weekly_hours_saved: figure(saved, "hours_per_week", `(${e.minutes} min x share ${row.share} - ${e.instances} instances x ${row.reviewMinutes} min review) / 60 = ${saved} h per week`, refs),
    setup_hours: figure(setup, "hours", `${setupTerms.join(" + ")} = ${setup} h`, refs),
    payback_weeks: figure(payback, "weeks", `setup ${setup} h / ${saved} h saved per week = ${payback} weeks`, refs),
    confidence: figure(conf, "ratio", `${confTerms.join(" x ")} = ${conf}`, refs),
  };
}
