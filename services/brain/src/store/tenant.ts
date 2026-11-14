// RunInTenant: the local stand-in for packages/db's withTenant (W1-C, m1-03; ADR 0013). One transaction with
// SET LOCAL app.tenant_id, app.member_id, app.principal_id, app.tenant_role and app.member_scope. The ids come only
// from a verified session or device token, never from a request body. No network I/O inside `fn`.
import type { SQL } from "bun";

export type Tx = SQL;

export interface TenantContext {
  tenantId: string;
  memberId: string;
  principalId: string;
  tenantRole: string;
  /** `tenant` only for audited aggregate jobs. */
  memberScope?: "member" | "tenant";
}

export type RunInTenant = <T>(ctx: TenantContext, fn: (tx: Tx) => Promise<T>) => Promise<T>;

export interface BunTenantOptions {
  /** Schema to put first on the search_path (tests use one schema per file). */
  schema?: string;
  /** Role to SET LOCAL ROLE to, for example offload_app (needs the session user to be a member of it). */
  appRole?: string;
}

export function bunRunInTenant(_sql: SQL, _opts: BunTenantOptions = {}): RunInTenant {
  throw new Error("not implemented");
}
