import type { Pool } from "pg";
import { withTenant } from "../tenancy.ts";
import type { DurableInput, WorkflowFn } from "../durable/port.ts";
import { writeAnchor } from "./anchor.ts";
import type { ServiceSigner } from "./signer.ts";

/** Hourly, UTC (ADR 0018). */
export const AUDIT_ANCHOR_CRON = "0 * * * *";
export const AUDIT_ANCHOR_WORKFLOW = "auditAnchor";

export interface AuditAnchorDeps {
  /** Pool connected as offload_app: writeAnchor runs through withTenant on it. */
  appPool: Pool;
  /** Pool connected as offload_jobs: only jobs_list_tenants() is called on it. */
  jobsPool: Pool;
  signer: ServiceSigner;
  clock: { now(): Date };
}

/**
 * The `auditAnchor` workflow body. Workflow input and step outputs hold ids only: the tenant list is uuids, a tenant's
 * step returns the anchored seq (or null). The head hash and signature stay in the row.
 */
export function auditAnchorWorkflows(deps: AuditAnchorDeps): Record<string, WorkflowFn> {
  return {
    [AUDIT_ANCHOR_WORKFLOW]: async (rt, _input: DurableInput) => {
      const { tenants } = await rt.step("list-tenants", async () => {
        const r = await deps.jobsPool.query<{ tenant_id: string }>("select tenant_id from jobs_list_tenants()");
        return { tenants: r.rows.map((x) => x.tenant_id) };
      });
      for (const tenantId of tenants) {
        await rt.step(`anchor:${tenantId}`, async () => {
          const out = await withTenant(
            deps.appPool,
            { tenantId, principalId: "job:audit_anchor", memberId: null, tenantRole: "service" },
            (tx) => writeAnchor(tx, tenantId, deps.signer, deps.clock.now()),
          );
          return { anchored_seq: out ? out.seq : null };
        });
      }
    },
  };
}
