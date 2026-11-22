// The understanding job: one observations.ingested event in, one runMemberUpdate out, at most once per event.
import type { WorkflowFn } from "@offload/db";
import type { MemberUpdateInput } from "../store/job.ts";
import type { RunInTenant } from "../store/tenant.ts";
import type { CaptureStore, IngestedEvent } from "./capture.ts";
import type { Embedder } from "./embed.ts";
import type { SpanLabeler } from "./labeler.ts";

export interface UnderstandingDeps {
  capture: CaptureStore;
  runBrain: RunInTenant;
  clock: () => number;
  embedder?: Embedder;
  labeler?: SpanLabeler;
  estimateFor?: MemberUpdateInput["estimateFor"];
}

export type UnderstandingStatus = "updated" | "duplicate" | "empty" | "paused" | "unknown_member";

export interface UnderstandingResult {
  status: UnderstandingStatus;
  eventId: string;
  days: string[];
  spans: number;
  tasks: number;
  instances: number;
}

/** The longest run of days one event analyses (the raw TTL is 30 days). */
export const MAX_ANALYSIS_DAYS = 31;

export async function runUnderstanding(_deps: UnderstandingDeps, _event: IngestedEvent): Promise<UnderstandingResult> {
  throw new Error("not implemented");
}

export async function drainUnderstanding(_deps: UnderstandingDeps, _opts: { tenantId: string; limit?: number }): Promise<UnderstandingResult[]> {
  throw new Error("not implemented");
}

export function understandingWorkflow(_deps: UnderstandingDeps): WorkflowFn {
  throw new Error("not implemented");
}
