import { jcs, sha256Hex } from "@offload/contracts";
import { ulid } from "./ids.ts";
import type { Tx } from "./tenancy.ts";

/**
 * Audit chain writer, ADR 0018. One chain per tenant:
 *   hash = sha256Hex(prev_hash || JCS(event_without_hash))
 * prev_hash is concatenated as its 64-character lowercase hex ASCII text; the first event uses 64 zeros.
 * event_without_hash = { tenant_id, seq, id, at, principal_id, action, subject_type, subject_id, rule_id, details,
 * prev_hash } with `at` as RFC 3339 UTC with milliseconds and absent optional fields as null.
 * Written fresh from ADR 0018 (no old-repo code copied).
 */

export const AUDIT_GENESIS_HASH = "0".repeat(64);
export const AUDIT_ACTION_RE = /^[a-z_]+\.[a-z_]+$/;
const ID_RE = /^[A-Za-z0-9_:.-]{1,128}$/;
const SUBJECT_TYPE_RE = /^[a-z_]{1,64}$/;
const DETAIL_KEY_RE = /^[a-z][a-z0-9_]{0,63}$/;
/** Ids and hashes only: no whitespace, at most 128 characters. */
const DETAIL_STRING_RE = /^\S{0,128}$/;
/** Whole details object as JCS: ids and hashes fit; free text split into words does not. */
const MAX_DETAILS_BYTES = 2048;

export class AuditEventError extends Error {
  readonly code = "audit_event_invalid";
  constructor(message: string) {
    super(message);
    this.name = "AuditEventError";
  }
}

export interface AuditEventInput {
  principalId: string;
  action: string;
  subjectType?: string;
  subjectId?: string;
  ruleId?: string;
  /** Ids and hashes only, never message bodies, recipients or screen text. */
  details: Record<string, unknown>;
}

export interface AuditEvent {
  tenant_id: string;
  seq: number;
  id: string;
  at: string;
  principal_id: string;
  action: string;
  subject_type: string | null;
  subject_id: string | null;
  rule_id: string | null;
  details: Record<string, unknown>;
  prev_hash: string;
}

export interface AuditRow extends AuditEvent {
  hash: string;
}

/** The chain formula, in one place. */
export function auditHash(event: AuditEvent): string {
  return sha256Hex(event.prev_hash + jcs(event));
}

function checkDetails(v: unknown, depth: number): void {
  if (depth > 4) throw new AuditEventError("audit details nest too deep");
  if (v === null || typeof v === "boolean") return;
  if (typeof v === "number") {
    if (!Number.isFinite(v)) throw new AuditEventError("audit details hold a non-finite number");
    return;
  }
  if (typeof v === "string") {
    if (!DETAIL_STRING_RE.test(v)) throw new AuditEventError("audit details hold ids and hashes only (no spaces, at most 128 characters)");
    return;
  }
  if (Array.isArray(v)) {
    if (v.length > 64) throw new AuditEventError("audit details array too long");
    for (const x of v) checkDetails(x, depth + 1);
    return;
  }
  if (typeof v === "object" && Object.getPrototypeOf(v) === Object.prototype) {
    const keys = Object.keys(v as object);
    if (keys.length > 64) throw new AuditEventError("audit details have too many keys");
    for (const k of keys) {
      if (!DETAIL_KEY_RE.test(k)) throw new AuditEventError("audit details keys are snake_case names");
      checkDetails((v as Record<string, unknown>)[k], depth + 1);
    }
    return;
  }
  throw new AuditEventError("audit details hold JSON values only");
}

function validate(e: AuditEventInput): void {
  if (typeof e.action !== "string" || !AUDIT_ACTION_RE.test(e.action)) throw new AuditEventError("audit action must match ^[a-z_]+\\.[a-z_]+$");
  if (typeof e.principalId !== "string" || !ID_RE.test(e.principalId)) throw new AuditEventError("audit principal_id must be an id");
  if (e.subjectType !== undefined && !SUBJECT_TYPE_RE.test(e.subjectType)) throw new AuditEventError("audit subject_type must be a snake_case name");
  if (e.subjectId !== undefined && !ID_RE.test(e.subjectId)) throw new AuditEventError("audit subject_id must be an id");
  if (e.ruleId !== undefined && !ID_RE.test(e.ruleId)) throw new AuditEventError("audit rule_id must be an id");
  if (typeof e.details !== "object" || e.details === null || Array.isArray(e.details)) throw new AuditEventError("audit details must be an object");
  checkDetails(e.details, 0);
  if (jcs(e.details).length > MAX_DETAILS_BYTES) throw new AuditEventError(`audit details over ${MAX_DETAILS_BYTES} bytes`);
}

/**
 * Appends one event to the current tenant's chain inside the caller's transaction, so a rollback leaves no event.
 * Takes the per-tenant advisory lock as its last lock, then reads the head and inserts. Call it last in the
 * transaction (ADR 0013): the lock is held until commit.
 */
export async function appendAudit(tx: Tx, input: AuditEventInput): Promise<AuditRow> {
  validate(input);
  const tenantId = (await tx.query<{ t: string | null }>("select nullif(current_setting('app.tenant_id', true), '')::uuid::text as t")).rows[0]?.t;
  if (!tenantId) throw new AuditEventError("appendAudit needs app.tenant_id (run it inside withTenant)");
  await tx.query("select pg_advisory_xact_lock(hashtextextended('audit:' || $1, 0))", [tenantId]);
  const head = (await tx.query<{ seq: string; hash: string }>(
    "select seq, hash from audit_events where tenant_id = $1 order by seq desc limit 1",
    [tenantId],
  )).rows[0];
  const event: AuditEvent = {
    tenant_id: tenantId,
    seq: head ? Number(head.seq) + 1 : 1,
    id: ulid(),
    at: new Date().toISOString(),
    principal_id: input.principalId,
    action: input.action,
    subject_type: input.subjectType ?? null,
    subject_id: input.subjectId ?? null,
    rule_id: input.ruleId ?? null,
    details: input.details,
    prev_hash: head ? head.hash : AUDIT_GENESIS_HASH,
  };
  const hash = auditHash(event);
  await tx.query(
    `insert into audit_events (tenant_id, seq, id, at, principal_id, action, subject_type, subject_id, rule_id, details, prev_hash, hash)
     values ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12)`,
    [event.tenant_id, event.seq, event.id, event.at, event.principal_id, event.action, event.subject_type, event.subject_id,
      event.rule_id, JSON.stringify(event.details), event.prev_hash, hash],
  );
  return { ...event, hash };
}

/** Result shape of GET /v1/audit-events/verify (API.md). */
export interface AuditVerifyResult {
  ok: boolean;
  checked: number;
  first_bad_seq?: number;
}

/**
 * Recomputes the current tenant's chain from the first event. Detects an edited row (hash mismatch), a deleted row
 * (seq gap or broken link) and a fork (a row whose prev_hash is not the previous row's hash).
 */
export async function verifyAuditChain(tx: Tx): Promise<AuditVerifyResult> {
  const rows = (await tx.query(
    `select tenant_id, seq, id, at, principal_id, action, subject_type, subject_id, rule_id, details, prev_hash, hash
     from audit_events where tenant_id = nullif(current_setting('app.tenant_id', true), '')::uuid order by seq`,
  )).rows;
  let prev = AUDIT_GENESIS_HASH;
  let expectedSeq = 1;
  for (const r of rows) {
    const seq = Number(r.seq);
    const event: AuditEvent = {
      tenant_id: r.tenant_id, seq, id: r.id, at: (r.at as Date).toISOString(), principal_id: r.principal_id,
      action: r.action, subject_type: r.subject_type, subject_id: r.subject_id, rule_id: r.rule_id, details: r.details,
      prev_hash: r.prev_hash,
    };
    if (seq !== expectedSeq || r.prev_hash !== prev || auditHash(event) !== r.hash) {
      return { ok: false, checked: rows.length, first_bad_seq: seq };
    }
    prev = r.hash;
    expectedSeq++;
  }
  return { ok: true, checked: rows.length };
}
