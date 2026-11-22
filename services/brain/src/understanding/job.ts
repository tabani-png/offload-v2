// The understanding job: one observations.ingested event in, one runMemberUpdate out, at most once per event.
// Order: claim the event (session advisory lock; a second consumer gets `busy`) -> duplicate check -> profile timezone
// (brain transaction) -> read by ts (capture transaction) -> build the window (no transaction: the optional labeler's
// model call happens here) -> runMemberUpdate under the member's profile lock (brain transaction, so two events of one
// member update the ledger one after the other) -> mark delivered (capture transaction). A failure records the
// attempt with a code and rethrows; a re-run after a crash rebuilds the same window (deterministic ids), which
// runMemberUpdate stores idempotently. A delivered event is never processed again; one that failed MAX_ATTEMPTS times
// is no longer drained. Logs and results carry ids and codes only.
import type { WorkflowFn } from "@offload/db";
import { addDays, dayOf } from "../records/dates.ts";
import { runMemberUpdate, type MemberUpdateInput } from "../store/job.ts";
import * as repo from "../store/repository.ts";
import type { RunInTenant, TenantContext } from "../store/tenant.ts";
import { MAX_ATTEMPTS, type CaptureStore, type IngestedEvent, type MemberRef } from "./capture.ts";
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
  /** Optional `label` route, built per event for its tenant and member (for example
   * `(m) => routerSpanLabeler(route, { tenant_id: m.tenantId, member_id: m.memberId })`), so budgets and audit are the
   * event's member's. Never required. */
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
  /** For `failed`: the error code recorded in outbox_deliveries.last_error_code. */
  error?: string;
}

export { MAX_ATTEMPTS };

/** The longest span of days in one understanding window (one read, one runMemberUpdate). An event's days are analysed
 * in as many windows as they need, oldest first. */
export const MAX_ANALYSIS_DAYS = 31;
/** A safety bound on one range: at most two years of days, ending at its last day (an import of older recordings is
 * analysed over its last two years). */
export const MAX_RANGE_DAYS = 731;
/** How late a live batch can arrive: ingest accepts live objects up to 7 days old (`too_old`, ADR 0020) and stores
 * them with partition `day` = the UTC date of `ts`. Without first_ts/last_ts the event's range covers rows whose
 * partition day is within this many days before the event. */
export const LIVE_LATE_DAYS = 7;
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

function daysBetween(first: string, last: string, cap: number): string[] {
  const out: string[] = [];
  let d = first < addDays(last, -(cap - 1)) ? addDays(last, -(cap - 1)) : first;
  while (d <= last) {
    out.push(d);
    d = addDays(d, 1);
  }
  return out;
}

/** The ts ranges an event touched: first_ts/last_ts when present, else one range per import space (and one for live
 * rows) over the member's rows ingested on the event's UTC day or the LIVE_LATE_DAYS days before it (live rows: day =
 * UTC date of ts, up to 7 days late; imported rows: day = the ingest date). Separate ranges keep an old import from
 * being cut off by the 31-day cap of one range that also holds today's live rows. */
async function rangesOf(capture: CaptureStore, ref: MemberRef, ev: IngestedEvent): Promise<Array<{ min: number; max: number }>> {
  const a = Date.parse(ev.payload.first_ts ?? "");
  const b = Date.parse(ev.payload.last_ts ?? "");
  if (Number.isFinite(a) && Number.isFinite(b)) return [{ min: Math.min(a, b), max: Math.max(a, b) }];
  const day = new Date(ev.createdAt).toISOString().slice(0, 10);
  const earliest = new Date(ev.createdAt - LIVE_LATE_DAYS * DAY_MS).toISOString().slice(0, 10);
  return capture.tsRangesOfDays(ref, earliest, day);
}

const rowKey = (r: { device_id: string; object_id: string }) => `${r.device_id}\u0000${r.object_id}`;

export async function runUnderstanding(deps: UnderstandingDeps, ev: IngestedEvent): Promise<UnderstandingResult> {
  const claim = await deps.capture.withEventLock(ev.tenantId, ev.eventId, () => runClaimed(deps, ev));
  return claim.locked ? claim.value : result("busy", ev);
}

async function runClaimed(deps: UnderstandingDeps, ev: IngestedEvent): Promise<UnderstandingResult> {
  const { capture } = deps;
  if (await capture.isDelivered(ev.tenantId, ev.eventId)) return result("duplicate", ev);
  // The cap holds on every path (drain and durable workflow): an exhausted event is not run again.
  if ((await capture.attempts(ev.tenantId, ev.eventId)) >= MAX_ATTEMPTS) return result("failed", ev, { error: "attempts_exhausted" });
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
    const ranges = await rangesOf(capture, ref, ev);
    if (ranges.length === 0) {
      await capture.recordAttempt(ev.tenantId, ev.eventId, null);
      return result("empty", ev);
    }
    // Each range becomes whole member-timezone days (at most MAX_RANGE_DAYS, ending at its last day). The days of all
    // ranges are analysed in windows that span at most MAX_ANALYSIS_DAYS, oldest first, each read by ts on its own; a
    // long import or a wide first_ts/last_ts range is never cut, only split (review 4 finding 2).
    const candidate = new Set<string>();
    for (const r of ranges) for (const d of daysBetween(dayOf(r.min, tz), dayOf(r.max, tz), MAX_RANGE_DAYS)) candidate.add(d);
    const chunks: string[][] = [];
    for (const d of [...candidate].sort()) {
      const cur = chunks[chunks.length - 1];
      if (cur !== undefined && d < addDays(cur[0]!, MAX_ANALYSIS_DAYS)) cur.push(d);
      else chunks.push([d]);
    }
    const workspaceId = await capture.workspaceOf(ref);
    const labeler = deps.labelerFor?.(ref);
    const analysed: string[] = [];
    let spans = 0;
    let tasks = 0;
    let instances = 0;
    let paused = false;
    for (const chunk of chunks) {
      const from = Date.parse(`${chunk[0]}T00:00:00Z`) - TZ_MARGIN_MS;
      const to = Date.parse(`${addDays(chunk[chunk.length - 1]!, 1)}T00:00:00Z`) + TZ_MARGIN_MS;
      const got = await capture.read(ref, from, to);
      const observations = [...new Map(got.observations.map((o) => [rowKey(o), o])).values()];
      const texts = [...new Map(got.texts.map((t) => [rowKey(t), t])).values()];
      // Only days that hold observations are analysed: a day without rows is never rebuilt from nothing (its live rows
      // may be past the raw TTL while an import widened the range).
      const withRows = new Set(observations.map((o) => dayOf(o.ts, tz)));
      const days = chunk.filter((d) => withRows.has(d));
      if (days.length === 0) continue;
      const window = await buildUnderstandingWindow(
        { timezone: tz, days, observations, texts },
        { ...(deps.embedder === undefined ? {} : { embedder: deps.embedder }), ...(labeler === undefined ? {} : { labeler }) },
      );
      if (window.spans.length === 0) continue;
      const now = deps.clock();
      const update = await deps.runBrain(ctx, async (tx) => {
        // One member's updates run one after the other: the ledger and propositions are read, merged and written back.
        await repo.lockProfile(tx);
        // Without a workspace no opportunity is ranked (estimateFor withheld), so workspaceId is never read: "" says so.
        return runMemberUpdate(tx, {
          window, now, workspaceId: workspaceId ?? "",
          ...(deps.estimateFor !== undefined && workspaceId !== null ? { estimateFor: deps.estimateFor } : {}),
        });
      });
      if (update.paused) {
        paused = true;
        break;
      }
      analysed.push(...days);
      spans += window.spans.length;
      tasks += window.tasks.length;
      instances += window.tasks.reduce((n, t) => n + t.instances.length, 0);
    }
    await capture.recordAttempt(ev.tenantId, ev.eventId, null);
    if (paused) return result("paused", ev);
    if (analysed.length === 0) return result("empty", ev);
    return result("updated", ev, { days: analysed, spans, tasks, instances });
  } catch (e) {
    await capture.recordAttempt(ev.tenantId, ev.eventId, errorCode(e)).catch(() => undefined);
    throw e;
  }
}

/** The in-process consumer: every pending event of one tenant, oldest first, one at a time. */
/** A failed event is recorded (code in outbox_deliveries) and the drain goes on with the next one; after MAX_ATTEMPTS
 * attempts the event is no longer pending. */
export async function drainUnderstanding(deps: UnderstandingDeps, opts: { tenantId: string; limit?: number }): Promise<UnderstandingResult[]> {
  const out: UnderstandingResult[] = [];
  for (const ev of await deps.capture.pendingEvents(opts.tenantId, opts.limit ?? 100, MAX_ATTEMPTS)) {
    try {
      out.push(await runUnderstanding(deps, ev));
    } catch (e) {
      out.push(result("failed", ev, { error: errorCode(e) }));
    }
  }
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
