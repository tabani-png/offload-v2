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

const IDENT = /^[a-z_][a-z0-9_]{0,62}$/;
export function ident(name: string): string {
  if (!IDENT.test(name)) throw new RangeError("not a plain SQL identifier");
  return name;
}
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export function bunRunInTenant(sql: SQL, opts: BunTenantOptions = {}): RunInTenant {
  const schema = opts.schema === undefined ? undefined : ident(opts.schema);
  const role = opts.appRole === undefined ? undefined : ident(opts.appRole);
  return <T>(ctx: TenantContext, fn: (tx: Tx) => Promise<T>): Promise<T> => {
    if (!UUID.test(ctx.tenantId) || !UUID.test(ctx.memberId)) return Promise.reject(new RangeError("tenant and member ids must be uuids"));
    return sql.begin(async (tx) => {
      if (schema !== undefined) await tx.unsafe(`SET LOCAL search_path TO ${schema}`);
      if (role !== undefined) await tx.unsafe(`SET LOCAL ROLE ${role}`);
      await tx.unsafe(
        "SELECT set_config('app.tenant_id', $1, true), set_config('app.member_id', $2, true), set_config('app.principal_id', $3, true), set_config('app.tenant_role', $4, true), set_config('app.member_scope', $5, true)",
        [ctx.tenantId, ctx.memberId, ctx.principalId, ctx.tenantRole, ctx.memberScope ?? "member"],
      );
      return fn(tx as unknown as Tx);
    }) as Promise<T>;
  };
}
