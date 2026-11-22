// The capture side of understanding: pending observations.ingested events, reads of observations and observation
// texts, and the consumer's delivery marks in outbox_deliveries (consumer `workflow:understanding`).
// Every read runs inside withTenant (packages/db, ADR 0013): tenant RLS always, and the member wall for the capture
// tables, which are read as the event's member. Rows hold masked C1 data; nothing here logs or returns text except
// the texts handed to the window builder.
import { withTenant, type TenantContext } from "@offload/db";
import type { CaptureObservation, CaptureText } from "./types.ts";

export const UNDERSTANDING_CONSUMER = "workflow:understanding";
/** Attempts after which a failing event is no longer returned by pendingEvents (its code stays in last_error_code). */
export const MAX_ATTEMPTS = 5;
/** Durable workflows run as this principal with role `service` (DATA_MODEL section 3). */
const PRINCIPAL = "durable";

/** An `observations.ingested` outbox event (API.md section 7). Payload as m3-01 writes it; ids and counts only. */
export interface IngestedEvent {
  tenantId: string;
  eventId: string;
  createdAt: number;
  payload: { device_id?: string; member_id?: string; seq?: number; accepted?: number; first_ts?: string; last_ts?: string };
}

export interface MemberRef {
  tenantId: string;
  memberId: string;
}

export interface CaptureStore {
  /** Undelivered `observations.ingested` events of a tenant with fewer than `maxAttempts` attempts (default
   * MAX_ATTEMPTS), oldest first. */
  pendingEvents(tenantId: string, limit: number, maxAttempts?: number): Promise<IngestedEvent[]>;
  /** Runs `fn` while holding the event's claim (a session advisory lock, released on return or when the connection
   * dies). Another consumer holding it gives `{ locked: false }` at once: one event never runs twice at a time. */
  withEventLock<T>(tenantId: string, eventId: string, fn: () => Promise<T>): Promise<{ locked: true; value: T } | { locked: false }>;
  getEvent(tenantId: string, eventId: string): Promise<IngestedEvent | null>;
  isDelivered(tenantId: string, eventId: string): Promise<boolean>;
  /** Attempts recorded for the event (0 when none). */
  attempts(tenantId: string, eventId: string): Promise<number>;
  /** Records one attempt; `error` (a code, never text) null marks the event delivered. */
  recordAttempt(tenantId: string, eventId: string, error: string | null): Promise<void>;
  /** The member exists in this tenant and is neither departed nor frozen (as the resolvers, DATA_MODEL section 3). */
  memberExists(m: MemberRef): Promise<boolean>;
  /** The member's first workspace (opportunities need one). */
  workspaceOf(m: MemberRef): Promise<string | null>;
  /** min/max `ts` of the member's rows whose partition `day` is in [fromDay, toDay] (UTC dates). */
  tsRangeOfDays(m: MemberRef, fromDay: string, toDay: string): Promise<{ min: number; max: number } | null>;
  /** Every observation and text of the member with `from <= ts < to`, read by `ts`. */
  read(m: MemberRef, from: number, to: number): Promise<{ observations: CaptureObservation[]; texts: CaptureText[] }>;
}

type WithTenantPool = Parameters<typeof withTenant>[0];
type Row = Record<string, any>;

const ms = (v: unknown): number => (v instanceof Date ? v.getTime() : new Date(String(v)).getTime());
const service = (tenantId: string): TenantContext => ({ tenantId, principalId: PRINCIPAL, memberId: null, tenantRole: "service" });
const asMember = (m: MemberRef): TenantContext => ({ tenantId: m.tenantId, principalId: PRINCIPAL, memberId: m.memberId, tenantRole: "service" });

const eventOf = (tenantId: string, r: Row): IngestedEvent => ({
  tenantId, eventId: r["id"], createdAt: ms(r["created_at"]), payload: (r["payload"] ?? {}) as IngestedEvent["payload"],
});

export interface CaptureStoreOptions {
  /** Pool for event claims. Each running event holds one of its connections (a session advisory lock) while its work
   * takes connections from `pool`; with one shared pool, as many concurrent claims as connections would leave no
   * connection for the work. `offload serve` passes a small dedicated pool here. Default: `pool`. */
  claimPool?: WithTenantPool;
}

export function pgCaptureStore(pool: WithTenantPool, opts: CaptureStoreOptions = {}): CaptureStore {
  const claimPool = opts.claimPool ?? pool;
  return {
    pendingEvents: (tenantId, limit, maxAttempts = MAX_ATTEMPTS) =>
      withTenant(pool, service(tenantId), async (tx) =>
        (await tx.query(
          `select e.id, e.payload, e.created_at from events_outbox e
            where e.type = 'observations.ingested'
              and not exists (select 1 from outbox_deliveries d where d.tenant_id = e.tenant_id and d.event_id = e.id
                              and d.consumer = $1 and (d.delivered_at is not null or d.attempts >= $3))
            order by e.created_at, e.id limit $2`,
          [UNDERSTANDING_CONSUMER, Math.max(1, Math.min(limit, 1000)), maxAttempts],
        )).rows.map((r) => eventOf(tenantId, r)),
      ),
    withEventLock: async (tenantId, eventId, fn) => {
      const key = `${UNDERSTANDING_CONSUMER}:${tenantId}:${eventId}`;
      // A plain session (no transaction is held open, so the network guard and the no-I/O rule are kept).
      const c = await claimPool.connect();
      // A connection whose unlock failed may still hold the lock: destroy it instead of returning it to the pool.
      let broken: Error | undefined;
      try {
        const got = (await c.query("select pg_try_advisory_lock(hashtextextended($1, 0)) as ok", [key])).rows[0]?.ok === true;
        if (!got) return { locked: false as const };
        try {
          return { locked: true as const, value: await fn() };
        } finally {
          await c.query("select pg_advisory_unlock(hashtextextended($1, 0))", [key]).catch((e: unknown) => {
            broken = e instanceof Error ? e : new Error("unlock failed");
          });
        }
      } finally {
        c.release(broken);
      }
    },
    getEvent: (tenantId, eventId) =>
      withTenant(pool, service(tenantId), async (tx) => {
        const r = (await tx.query("select id, payload, created_at from events_outbox where id = $1 and type = 'observations.ingested'", [eventId])).rows[0];
        return r === undefined ? null : eventOf(tenantId, r);
      }),
    attempts: (tenantId, eventId) =>
      withTenant(pool, service(tenantId), async (tx) =>
        Number((await tx.query("select attempts from outbox_deliveries where event_id = $1 and consumer = $2", [eventId, UNDERSTANDING_CONSUMER])).rows[0]?.["attempts"] ?? 0),
      ),
    isDelivered: (tenantId, eventId) =>
      withTenant(pool, service(tenantId), async (tx) =>
        (await tx.query("select 1 from outbox_deliveries where event_id = $1 and consumer = $2 and delivered_at is not null", [eventId, UNDERSTANDING_CONSUMER])).rows.length > 0,
      ),
    recordAttempt: (tenantId, eventId, error) =>
      withTenant(pool, service(tenantId), async (tx) => {
        await tx.query(
          `insert into outbox_deliveries (tenant_id, event_id, consumer, attempts, delivered_at, last_error_code)
           values ($1, $2, $3, 1, case when $4::text is null then now() end, $4::text)
           on conflict (tenant_id, event_id, consumer) do update
             set attempts = outbox_deliveries.attempts + 1,
                 delivered_at = coalesce(outbox_deliveries.delivered_at, excluded.delivered_at),
                 last_error_code = excluded.last_error_code`,
          [tenantId, eventId, UNDERSTANDING_CONSUMER, error],
        );
      }),
    memberExists: (m) =>
      withTenant(pool, asMember(m), async (tx) => (await tx.query("select 1 from members where id = $1 and state not in ('departed', 'frozen')", [m.memberId])).rows.length > 0),
    workspaceOf: (m) =>
      withTenant(pool, asMember(m), async (tx) => {
        const r = (await tx.query("select workspace_id from workspace_members where member_id = $1 order by workspace_id limit 1", [m.memberId])).rows[0];
        return r === undefined ? null : String(r["workspace_id"]);
      }),
    tsRangeOfDays: (m, fromDay, toDay) =>
      withTenant(pool, asMember(m), async (tx) => {
        const r = (await tx.query("select min(ts) as mn, max(ts) as mx from observations where member_id = $1 and day between $2::date and $3::date", [m.memberId, fromDay, toDay])).rows[0];
        return r === undefined || r["mn"] === null ? null : { min: ms(r["mn"]), max: ms(r["mx"]) };
      }),
    read: (m, from, to) =>
      withTenant(pool, asMember(m), async (tx) => {
        const range = [m.memberId, new Date(from).toISOString(), new Date(to).toISOString()];
        const obs = (await tx.query(
          `select device_id, object_id, ts, kind, app_bundle_id, app_name, title, host, doc, keys, clicks, source, import_id
             from observations where member_id = $1 and ts >= $2::timestamptz and ts < $3::timestamptz order by ts, object_id`,
          range,
        )).rows;
        const texts = (await tx.query(
          `select device_id, object_id, ts, text, text_source, app_bundle_id
             from observation_texts where member_id = $1 and ts >= $2::timestamptz and ts < $3::timestamptz order by ts, object_id`,
          range,
        )).rows;
        return {
          observations: obs.map((r): CaptureObservation => ({
            device_id: String(r["device_id"]), object_id: r["object_id"], ts: ms(r["ts"]), kind: r["kind"], app_bundle_id: r["app_bundle_id"],
            app_name: r["app_name"], title: r["title"], host: r["host"], doc: r["doc"], keys: r["keys"], clicks: r["clicks"], source: r["source"],
            import_id: r["import_id"] === null ? null : String(r["import_id"]),
          })),
          texts: texts.map((r): CaptureText => ({
            device_id: String(r["device_id"]), object_id: r["object_id"], ts: ms(r["ts"]), text: r["text"], text_source: r["text_source"], app_bundle_id: r["app_bundle_id"],
          })),
        };
      }),
  };
}
