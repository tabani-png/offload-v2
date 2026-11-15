import type { Pool, PoolClient } from "pg";
import {
  appendAudit, createPersonalTenant, uuidv7, withTenant, withTransaction, type TenantContext,
} from "../../src/index.ts";
import type { PgTenantFixture } from "@offload/testkit";

/** A fresh personal tenant (its chain starts with tenant.created at seq 1). */
export async function newTenant(app: Pool): Promise<TenantContext> {
  const t = await withTransaction(app, (tx) => createPersonalTenant(tx, { idpSubject: `oidc|${uuidv7()}`, email: "a@example.test" }));
  return { tenantId: t.tenantId, principalId: t.memberId, memberId: t.memberId, tenantRole: "owner" };
}

/** Appends `n` events to the tenant's chain (one transaction). */
export async function appendN(app: Pool, ctx: TenantContext, n: number): Promise<void> {
  await withTenant(app, ctx, async (tx) => {
    for (let i = 0; i < n; i++) {
      await appendAudit(tx, { principalId: ctx.principalId, action: "batch.committed", subjectType: "batch", subjectId: `b-${i}`, details: { i } });
    }
  });
}

/**
 * Runs `fn` as offload_migrator with the append-only trigger of `table` disabled, then restores it. The tenant setting
 * is set so the forced tenant policy lets the migrator see the tenant's rows.
 */
export async function tamper(
  fx: PgTenantFixture, tenantId: string, fn: (c: PoolClient) => Promise<void>, table: "audit_events" | "audit_anchors" = "audit_events",
): Promise<void> {
  const c = await fx.migrator.connect();
  try {
    await c.query("begin");
    await c.query("select set_config('app.tenant_id', $1, true)", [tenantId]);
    await c.query(`alter table ${table} disable trigger append_only_rows`);
    await fn(c);
    await c.query(`alter table ${table} enable trigger append_only_rows`);
    await c.query("commit");
  } catch (e) {
    await c.query("rollback").catch(() => {});
    throw e;
  } finally {
    c.release();
  }
}
