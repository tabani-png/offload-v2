// The capture side of understanding: pending events, reads of observations and texts, delivery marks.
import type { CaptureObservation, CaptureText } from "./types.ts";

export const UNDERSTANDING_CONSUMER = "workflow:understanding";

/** An `observations.ingested` outbox event (API.md section 7). Payload as m3-01 writes it. */
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
  /** Undelivered `observations.ingested` events of a tenant, oldest first. */
  pendingEvents(tenantId: string, limit: number): Promise<IngestedEvent[]>;
  getEvent(tenantId: string, eventId: string): Promise<IngestedEvent | null>;
  isDelivered(tenantId: string, eventId: string): Promise<boolean>;
  /** Records one attempt; `error` null marks the event delivered. */
  recordAttempt(tenantId: string, eventId: string, error: string | null): Promise<void>;
  memberExists(m: MemberRef): Promise<boolean>;
  /** The member's first workspace (opportunities need one). */
  workspaceOf(m: MemberRef): Promise<string | null>;
  /** min/max `ts` of the member's rows whose partition `day` is in [fromDay, toDay] (UTC dates). */
  tsRangeOfDays(m: MemberRef, fromDay: string, toDay: string): Promise<{ min: number; max: number } | null>;
  /** Every observation and text of the member with `from <= ts < to`, read by `ts`. */
  read(m: MemberRef, from: number, to: number): Promise<{ observations: CaptureObservation[]; texts: CaptureText[] }>;
}

type WithTenantPool = Parameters<typeof import("@offload/db").withTenant>[0];

export function pgCaptureStore(_pool: WithTenantPool): CaptureStore {
  const no = () => Promise.reject(new Error("not implemented"));
  return { pendingEvents: no, getEvent: no, isDelivered: no, recordAttempt: no, memberExists: no, workspaceOf: no, tsRangeOfDays: no, read: no };
}
