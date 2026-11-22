// The understanding job: one observations.ingested event in, one runMemberUpdate out, at most once per event.
// Order: duplicate check -> profile timezone (brain transaction) -> read by ts (capture transaction) -> build the window
// (no transaction: the optional labeler's model call happens here) -> runMemberUpdate (brain transaction) -> mark
// delivered (capture transaction). A failure records the attempt with a code and rethrows; a re-run after a crash
// rebuilds the same window (deterministic ids), which runMemberUpdate stores idempotently. A delivered event is never
// processed again. Logs and results carry ids and counts only.
import type { WorkflowFn } from "@offload/db";
import { addDays, dayOf } from "../records/dates.ts";
import { runMemberUpdate, type MemberUpdateInput } from "../store/job.ts";
import * as repo from "../store/repository.ts";
import type { RunInTenant, TenantContext } from "../store/tenant.ts";
import type { CaptureStore, IngestedEvent, MemberRef } from "./capture.ts";
import type { Embedder } from "./embed.ts";
import type { SpanLabeler } from "./labeler.ts";
import { buildUnderstandingWindow } from "./window.ts";

export interface UnderstandingDeps {
  capture: CaptureStore;
  /** The brain's user-model store (services/brain/sql), one transaction per call. */
  runBrain: RunInTenant;
  clock: () => number;
  /** Default: the local embedder. */
  embedder?: Embedder;
  /** Optional `label` route (routerSpanLabeler). Never required. */
  labeler?: SpanLabeler;
  /** Optional `label` route per member (routerSpanLabeler built for the event's tenant and member). */
  labelerFor?: (m: MemberRef) => SpanLabeler | undefined;
  /** Fix rules (m5-04), passed through to runMemberUpdate. */
  estimateFor?: MemberUpdateInput["estimateFor"];
}

export type UnderstandingStatus = "updated" | "duplicate" | "busy" | "failed" | "empty" | "paused" | "unknown_member";

export interface UnderstandingResult {
  status: UnderstandingStatus;
  eventId: string;
  days: string[];
  spans: number;
  tasks: number;
  instances: number;
}

/** Attempts after which a failing event is no longer retried by the drain. */
export const MAX_ATTEMPTS = 5;

/** The longest run of days one event analyses (the raw TTL is 30 days). */
export const MAX_ANALYSIS_DAYS = 31;
/** Margin around the asked days when reading by ts: covers every timezone offset. */
const TZ_MARGIN_MS = 14 * 3_600_000;
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const DAY_MS = 86_400_000;

const result = (status: UnderstandingStatus, ev: IngestedEvent, extra: Partial<UnderstandingResult> = {}): UnderstandingResult => ({
  status, eventId: ev.eventId, days: [], spans: 0, tasks: 0, instances: 0, ...extra,
});

function errorCode(e: unknown): string {
  const c = (e as { code?: unknown } | null)?.code;
  return typeof c === "string" && /^[a-z_]{1,64}$/.test(c) ? c : "understanding_failed";
}

function daysBetween(first: string, last: string): string[] {
  const out: string[] = [];
  let d = first < addDays(last, -(MAX_ANALYSIS_DAYS - 1)) ? addDays(last, -(MAX_ANALYSIS_DAYS - 1)) : first;
  while (d <= last) {
    out.push(d);
    d = addDays(d, 1);
  }
  return out;
}

/** The ts range an event touched: first_ts/last_ts when present, else the member's rows ingested on the event's UTC
 * day or the day before (live rows: day = UTC date of ts; imported rows: day = the ingest date). */
async function rangeOf(capture: CaptureStore, ref: MemberRef, ev: IngestedEvent): Promise<{ min: number; max: number } | null> {
  const a = Date.parse(ev.payload.first_ts ?? "");
  const b = Date.parse(ev.payload.last_ts ?? "");
  if (Number.isFinite(a) && Number.isFinite(b)) return { min: Math.min(a, b), max: Math.max(a, b) };
  const day = new Date(ev.createdAt).toISOString().slice(0, 10);
  const before = new Date(ev.createdAt - DAY_MS).toISOString().slice(0, 10);
  return capture.tsRangeOfDays(ref, before, day);
}

export async function runUnderstanding(deps: UnderstandingDeps, ev: IngestedEvent): Promise<UnderstandingResult> {
  const { capture } = deps;
  if (await capture.isDelivered(ev.tenantId, ev.eventId)) return result("duplicate", ev);
  try {
    const memberId = ev.payload.member_id ?? "";
    const ref: MemberRef = { tenantId: ev.tenantId, memberId };
    if (!UUID.test(memberId) || !(await capture.memberExists(ref))) {
      // Nothing to analyse, ever: deliver so it is not retried.
      await capture.recordAttempt(ev.tenantId, ev.eventId, null);
      return result("unknown_member", ev);
    }
    const ctx: TenantContext = { tenantId: ev.tenantId, memberId, principalId: "durable", tenantRole: "service" };
    const profile = await deps.runBrain(ctx, (tx) => repo.getProfile(tx));
    if (profile.learning_paused) {
      await capture.recordAttempt(ev.tenantId, ev.eventId, null);
      return result("paused", ev);
    }
    const tz = profile.timezone;
    const range = await rangeOf(capture, ref, ev);
    if (range === null) {
      await capture.recordAttempt(ev.tenantId, ev.eventId, null);
      return result("empty", ev);
    }
    const days = daysBetween(dayOf(range.min, tz), dayOf(range.max, tz));
    const from = Date.parse(`${days[0]}T00:00:00Z`) - TZ_MARGIN_MS;
    const to = Date.parse(`${addDays(days[days.length - 1]!, 1)}T00:00:00Z`) + TZ_MARGIN_MS;
    const rows = await capture.read(ref, from, to);
    const window = await buildUnderstandingWindow(
      { timezone: tz, days, observations: rows.observations, texts: rows.texts },
      { ...(deps.embedder === undefined ? {} : { embedder: deps.embedder }), ...(deps.labeler === undefined ? {} : { labeler: deps.labeler }) },
    );
    if (window.spans.length === 0) {
      await capture.recordAttempt(ev.tenantId, ev.eventId, null);
      return result("empty", ev, { days });
    }
    const workspaceId = await capture.workspaceOf(ref);
    const now = deps.clock();
    const update = await deps.runBrain(ctx, (tx) =>
      runMemberUpdate(tx, {
        window, now, workspaceId: workspaceId ?? ev.tenantId,
        ...(deps.estimateFor !== undefined && workspaceId !== null ? { estimateFor: deps.estimateFor } : {}),
      }),
    );
    await capture.recordAttempt(ev.tenantId, ev.eventId, null);
    return result(update.paused ? "paused" : "updated", ev, {
      days, spans: window.spans.length, tasks: window.tasks.length, instances: window.tasks.reduce((n, t) => n + t.instances.length, 0),
    });
  } catch (e) {
    await capture.recordAttempt(ev.tenantId, ev.eventId, errorCode(e)).catch(() => undefined);
    throw e;
  }
}

/** The in-process consumer: every pending event of one tenant, oldest first, one at a time. */
export async function drainUnderstanding(deps: UnderstandingDeps, opts: { tenantId: string; limit?: number }): Promise<UnderstandingResult[]> {
  const out: UnderstandingResult[] = [];
  for (const ev of await deps.capture.pendingEvents(opts.tenantId, opts.limit ?? 100)) out.push(await runUnderstanding(deps, ev));
  return out;
}

/** A durable-runtime workflow body for one event. Input `{ tenant_id, event_id }`; its step output is the status only. */
export function understandingWorkflow(deps: UnderstandingDeps): WorkflowFn {
  return async (rt, input) => {
    await rt.step("understanding", async () => {
      const eventId = typeof input["event_id"] === "string" ? input["event_id"] : "";
      const ev = UUID.test(eventId) ? await deps.capture.getEvent(input.tenant_id, eventId) : null;
      return ev === null ? "unknown_event" : (await runUnderstanding(deps, ev)).status;
    });
  };
}
