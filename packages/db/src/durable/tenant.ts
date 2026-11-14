import type { Pool, PoolClient } from "pg";

/**
 * Minimal withTenant: one transaction with `app.tenant_id` set locally. m1-03 (tenancy and RLS) replaces this file;
 * keep the signature stable.
 */
export async function withTenant<T>(pool: Pool, tenantId: string, fn: (client: PoolClient) => Promise<T>): Promise<T> {
  const client = await pool.connect();
  try {
    await client.query("begin");
    await client.query("select set_config('app.tenant_id', $1, true)", [tenantId]);
    const out = await fn(client);
    await client.query("commit");
    return out;
  } catch (err) {
    await client.query("rollback").catch(() => {});
    throw err;
  } finally {
    client.release();
  }
}
