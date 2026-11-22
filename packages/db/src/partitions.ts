import type { Tx } from "./tenancy.ts";

/**
 * Creates daily partitions of observations and observation_texts from `fromDay` (YYYY-MM-DD, UTC) for `days` days,
 * with ENABLE + FORCE RLS and both policies on each at creation. Idempotent; returns the partitions it created.
 * Runs as offload_retention (the daily retention workflow, m3-01) through the SECURITY DEFINER ensure_partitions().
 */
export async function ensurePartitions(tx: Tx, fromDay: string, days: number): Promise<string[]> {
  if (!/^\d{4}-\d{2}-\d{2}$/.test(fromDay)) throw new TypeError("ensurePartitions: fromDay must be YYYY-MM-DD");
  if (!Number.isInteger(days) || days < 1 || days > 366) throw new TypeError("ensurePartitions: days must be 1..366");
  const r = await tx.query<{ p: string }>("select p from ensure_partitions($1::date, $2) as p", [fromDay, days]);
  return r.rows.map((x) => x.p);
}
