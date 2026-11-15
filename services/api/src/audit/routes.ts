import type { Context, Hono } from "hono";
import type { Pool } from "pg";
import { AuditEventListSchema, AuditEventSchema, AuditVerifyResultSchema } from "@offload/contracts";
import { appendAudit, verifyChain, withTenant, type ServiceSigner, type TenantContext } from "@offload/db";
import { ApiError, invalidRequest } from "../http.ts";

/**
 * The audit read and verify routes (m2-12, docs/API.md "Metrics, audit and policy"). Tenant roles owner, admin and
 * auditor only. Responses are built field by field and parsed with the contract schemas, so `tenant_id` never leaves.
 */

type Role = "owner" | "admin" | "member" | "auditor";

export interface AuditPrincipal {
  tenantId: string;
  memberId: string;
  tenantRole: Role;
}

export interface AuditRoutesDeps {
  /** Pool connected as offload_app. */
  pool: Pool;
  /** Absent: GET /v1/audit-events/verify answers 404 not_found (it cannot check anchor signatures). */
  signer?: ServiceSigner | undefined;
  authenticate(c: Context): Promise<AuditPrincipal>;
}

const MAX_LIMIT = 200;
const DEFAULT_LIMIT = 50;

export function mountAudit(app: Hono, deps: AuditRoutesDeps): void {
  const ctxOf = (p: AuditPrincipal): TenantContext => ({ tenantId: p.tenantId, principalId: p.memberId, memberId: p.memberId, tenantRole: p.tenantRole });
  const allow = (p: AuditPrincipal) => {
    if (p.tenantRole === "member") throw new ApiError(403, "forbidden", "audit events are for owners, admins and auditors");
  };

  app.get("/v1/audit-events", async (c) => {
    const p = await deps.authenticate(c);
    allow(p);
    const rawLimit = c.req.query("limit");
    let limit = DEFAULT_LIMIT;
    if (rawLimit !== undefined) {
      if (!/^[0-9]{1,4}$/.test(rawLimit) || Number(rawLimit) < 1 || Number(rawLimit) > MAX_LIMIT) throw invalidRequest(`limit must be 1 to ${MAX_LIMIT}`);
      limit = Number(rawLimit);
    }
    const rawCursor = c.req.query("cursor");
    if (rawCursor !== undefined && (!/^[0-9]{1,15}$/.test(rawCursor) || Number(rawCursor) < 1)) throw invalidRequest("cursor is not valid");
    const rows = await withTenant(deps.pool, ctxOf(p), async (tx) =>
      (await tx.query(
        `select seq, id, at, principal_id, action, subject_type, subject_id, rule_id, details, prev_hash, hash
         from audit_events where tenant_id = $1 and ($2::bigint is null or seq < $2::bigint) order by seq desc limit $3`,
        [p.tenantId, rawCursor ?? null, limit + 1],
      )).rows);
    const page = rows.slice(0, limit);
    const items = page.map((r) => AuditEventSchema.parse({
      seq: Number(r.seq), id: r.id, at: (r.at as Date).toISOString(), principal_id: r.principal_id, action: r.action,
      subject_type: r.subject_type, subject_id: r.subject_id, rule_id: r.rule_id, details: r.details,
      prev_hash: r.prev_hash, hash: r.hash,
    }));
    const next = rows.length > limit && items.length > 0 ? String(items[items.length - 1]!.seq) : null;
    c.header("cache-control", "no-store");
    return c.json(AuditEventListSchema.parse({ items, next_cursor: next }));
  });

  app.get("/v1/audit-events/verify", async (c) => {
    const p = await authenticateVerify(c);
    const signer = deps.signer!;
    const result = await withTenant(deps.pool, ctxOf(p), async (tx) => {
      const out = AuditVerifyResultSchema.parse(await verifyChain(tx, p.tenantId, signer));
      await appendAudit(tx, {
        principalId: p.memberId, action: "audit.verified", subjectType: "tenant", subjectId: p.tenantId,
        details: { ok: out.ok, checked: out.checked },
      });
      return out;
    });
    c.header("cache-control", "no-store");
    return c.json(result);
  });

  async function authenticateVerify(c: Context): Promise<AuditPrincipal> {
    const p = await deps.authenticate(c);
    allow(p);
    if (!deps.signer) throw new ApiError(404, "not_found", "audit verification is not configured");
    return p;
  }
}
