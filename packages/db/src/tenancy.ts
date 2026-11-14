import { AsyncLocalStorage } from "node:async_hooks";
import type { Pool, PoolClient, QueryResult, QueryResultRow } from "pg";

/**
 * withTenant, ADR 0013. One transaction with the session settings the RLS policies read, set with SET LOCAL.
 * The tenant id comes only from a verified session or device token, never from a request body.
 */

export type TenantRole = "owner" | "admin" | "member" | "auditor" | "service";
export type MemberScope = "member" | "tenant";

export interface TenantContext {
  tenantId: string;
  /** Whoever makes the request: a member, a device, a service principal or a routine. */
  principalId: string;
  /** null for service work: member-isolated tables then show no rows unless memberScope is "tenant". */
  memberId: string | null;
  tenantRole: TenantRole;
  /** "tenant" only for audited aggregate jobs. Default "member". */
  memberScope?: MemberScope;
}

/** What `fn` gets: queries on the open transaction, nothing else (no release, no commit, no new connection). */
export interface Tx {
  query<R extends QueryResultRow = any>(text: string, values?: unknown[]): Promise<QueryResult<R>>;
}

export class NetworkIoInTransactionError extends Error {
  readonly code = "network_io_in_transaction";
  constructor() {
    super("network I/O inside withTenant: make the call outside the transaction and write its result in a second one");
    this.name = "NetworkIoInTransactionError";
  }
}

const inTransaction = new AsyncLocalStorage<true>();
let guardInstalled = false;

/**
 * Patches globalThis.fetch so a call made while a withTenant or withTransaction callback runs throws
 * NetworkIoInTransactionError; calls outside those callbacks go through unchanged. Tests install it (testkit).
 */
export function installNetworkGuard(): void {
  if (guardInstalled) return;
  guardInstalled = true;
  const original = globalThis.fetch;
  const guarded = ((...args: Parameters<typeof fetch>) => {
    if (inTransaction.getStore()) return Promise.reject(new NetworkIoInTransactionError());
    return original(...args);
  }) as typeof fetch;
  Object.assign(guarded, original);
  globalThis.fetch = guarded;
}

/** True while a withTenant or withTransaction callback runs (for other I/O guards). */
export function insideTransaction(): boolean {
  return inTransaction.getStore() === true;
}

type BeforeCommitHook = (tx: Tx) => void | Promise<void>;
const beforeCommitHooks = new Set<BeforeCommitHook>();

/** Registers a hook run inside every transaction just before COMMIT; returns its remover. Tests only (fault
 * injection through testkit's onBeforeCommit). */
export function registerBeforeCommit(hook: BeforeCommitHook): () => void {
  beforeCommitHooks.add(hook);
  return () => void beforeCommitHooks.delete(hook);
}

function txOf(client: PoolClient): Tx {
  return { query: (text, values) => client.query(text, values as unknown[] | undefined) };
}

async function run<T>(pool: Pool, setup: (c: PoolClient) => Promise<void>, fn: (tx: Tx) => Promise<T>): Promise<T> {
  const client = await pool.connect();
  let broken = false;
  try {
    await client.query("begin");
    await setup(client);
    const tx = txOf(client);
    const out = await inTransaction.run(true, () => fn(tx));
    for (const hook of [...beforeCommitHooks]) await inTransaction.run(true, async () => hook(tx));
    await client.query("commit");
    return out;
  } catch (err) {
    await client.query("rollback").catch(() => {
      broken = true;
    });
    throw err;
  } finally {
    client.release(broken);
  }
}

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/** Runs `fn` in one transaction with app.tenant_id, app.principal_id, app.member_id, app.tenant_role and
 * app.member_scope set locally. No network I/O inside `fn`. */
export async function withTenant<T>(pool: Pool, ctx: TenantContext, fn: (tx: Tx) => Promise<T>): Promise<T> {
  if (!UUID_RE.test(ctx.tenantId)) throw new TypeError("withTenant: tenantId must be a uuid");
  if (ctx.memberId !== null && !UUID_RE.test(ctx.memberId)) throw new TypeError("withTenant: memberId must be a uuid or null");
  if (!ctx.principalId) throw new TypeError("withTenant: principalId is required");
  const scope: MemberScope = ctx.memberScope ?? "member";
  if (scope !== "member" && scope !== "tenant") throw new TypeError("withTenant: memberScope must be member or tenant");
  return run(
    pool,
    async (c) => {
      await c.query(
        `select set_config('app.tenant_id', $1, true), set_config('app.principal_id', $2, true),
                set_config('app.member_id', $3, true), set_config('app.tenant_role', $4, true),
                set_config('app.member_scope', $5, true)`,
        [ctx.tenantId, ctx.principalId, ctx.memberId ?? "", ctx.tenantRole, scope],
      );
    },
    fn,
  );
}

/** A transaction with no tenant set, for bootstrap writes such as createPersonalTenant. Same guards as withTenant. */
export async function withTransaction<T>(pool: Pool, fn: (tx: Tx) => Promise<T>): Promise<T> {
  return run(pool, async () => {}, fn);
}
