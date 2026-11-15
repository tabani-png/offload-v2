import type { Pool } from "pg";
import { ensurePartitions, loadConfig, uuidv7, withTenant, withTransaction, type DbConfig, type DurableRuntime, type WorkflowFn } from "@offload/db";
import type { Clock } from "../clock.ts";

/**
 * retentionPurge: the daily durable workflow (03:15 UTC) that enforces the raw and text retention classes
 * (DATA_MODEL.md section 1; TTLs from packages/db/src/config.ts, never numbers written here). It runs as
 * offload_retention: it creates the next daily partitions, drops capture partitions that lie wholly before the cutoff
 * (`retention_drop_partition`), deletes the few expired rows that sat in the default partition, and writes `purge_log`
 * (`raw_ttl`, `text_ttl`) for each tenant that lost rows.
 */

export const RETENTION_WORKFLOW = "retentionPurge";
export const RETENTION_CRON = "15 3 * * *";
/** Daily partitions created ahead of today, so ingest rows land in their own day's partition. */
const PARTITIONS_AHEAD = 3;

export interface RetentionDeps {
  /** Pool connected as offload_retention. */
  pool: Pool;
  clock: Clock;
  /** Defaults to loadConfig() (the OFFLOAD_*_TTL_DAYS variables). */
  config?: Pick<DbConfig, "rawTtlDays" | "textTtlDays">;
}

export interface RetentionResult {
  rawCutoff: string;
  textCutoff: string;
  partitionsDropped: string[];
  tenants: number;
  rowsDeleted: { observations: number; observation_texts: number };
}

const dayString = (ms: number) => new Date(ms).toISOString().slice(0, 10);
const startOfDay = (ms: number) => Date.parse(`${dayString(ms)}T00:00:00Z`);

export async function runRetentionPurge(deps: RetentionDeps): Promise<RetentionResult> {
  const cfg = deps.config ?? loadConfig();
  const nowMs = deps.clock.now().getTime();
  const today = dayString(nowMs);
  // A row of day D is expired when D < today - ttl; a partition for day D (range D to D+1) is expired when D+1 <= cutoff.
  const rawCutoff = dayString(startOfDay(nowMs) - cfg.rawTtlDays * 86_400_000);
  const textCutoff = dayString(startOfDay(nowMs) - cfg.textTtlDays * 86_400_000);
  const service = (tenantId: string) => ({ tenantId, principalId: "retention", memberId: null, tenantRole: "service" as const, memberScope: "tenant" as const });

  await withTransaction(deps.pool, (tx) => ensurePartitions(tx, today, PARTITIONS_AHEAD));

  const tenants = (await deps.pool.query<{ tenant_id: string }>("select tenant_id from jobs_list_tenants()")).rows.map((r) => r.tenant_id);

  // Count what each tenant is about to lose, before the partitions go.
  const counts = new Map<string, { observations: number; observation_texts: number }>();
  for (const tenantId of tenants) {
    counts.set(tenantId, await withTenant(deps.pool, service(tenantId), async (tx) => ({
      observations: (await tx.query<{ n: number }>("select count(*)::int as n from observations where day < $1::date", [rawCutoff])).rows[0]!.n,
      observation_texts: (await tx.query<{ n: number }>("select count(*)::int as n from observation_texts where day < $1::date", [textCutoff])).rows[0]!.n,
    })));
  }

  // Drop whole expired partitions. The database refuses a cutoff that is not in its own past, so a skewed clock cannot
  // drop today's data; the row delete below still enforces the TTL then.
  const dbToday = (await deps.pool.query<{ d: string }>("select current_date::text as d")).rows[0]!.d;
  const partitionsDropped: string[] = [];
  const parts = (await deps.pool.query<{ part: string; parent: string; upper: string }>(
    `select c.relname as part, p.relname as parent,
            (regexp_match(pg_get_expr(c.relpartbound, c.oid), 'TO \\(''([0-9-]+)''\\)'))[1] as upper
       from pg_inherits i join pg_class c on c.oid = i.inhrelid join pg_class p on p.oid = i.inhparent
       join pg_namespace n on n.oid = p.relnamespace
      where n.nspname = 'public' and p.relname in ('observations', 'observation_texts') and c.relname ~ '_p[0-9]{8}$'`,
  )).rows;
  for (const part of parts) {
    const cutoff = part.parent === "observations" ? rawCutoff : textCutoff;
    if (part.upper === null || part.upper > cutoff || cutoff >= dbToday) continue;
    await deps.pool.query("select retention_drop_partition(('public.' || quote_ident($1))::regclass, $2::date)", [part.part, cutoff]);
    partitionsDropped.push(part.part);
  }

  // Rows outside any daily partition (the default partition), then the log.
  const total = { observations: 0, observation_texts: 0 };
  for (const tenantId of tenants) {
    const lost = counts.get(tenantId)!;
    await withTenant(deps.pool, service(tenantId), async (tx) => {
      await tx.query("delete from observations where day < $1::date", [rawCutoff]);
      await tx.query("delete from observation_texts where day < $1::date", [textCutoff]);
      for (const [scope, table, cutoff] of [["raw_ttl", "observations", rawCutoff], ["text_ttl", "observation_texts", textCutoff]] as const) {
        if (lost[table] === 0) continue;
        await tx.query(
          "insert into purge_log (tenant_id, id, scope, scope_ref, rows_deleted, requested_by) values ($1, $2, $3, $4, $5, 'retention')",
          [tenantId, uuidv7(), scope, `before:${cutoff}`, JSON.stringify({ [table]: lost[table] })],
        );
      }
    });
    total.observations += lost.observations;
    total.observation_texts += lost.observation_texts;
  }
  return { rawCutoff, textCutoff, partitionsDropped, tenants: tenants.length, rowsDeleted: total };
}

/** The workflow body to register under RETENTION_WORKFLOW. Its step output holds counts only (ids-only rule). */
export function retentionPurgeWorkflow(deps: RetentionDeps): WorkflowFn {
  return async (rt) => {
    await rt.step("purge", async () => {
      const r = await runRetentionPurge(deps);
      return { tenants: r.tenants, partitions_dropped: r.partitionsDropped.length };
    });
  };
}

/** Declares the daily schedule (UTC); call on every boot. */
export function scheduleRetentionPurge(rt: DurableRuntime): Promise<void> {
  return rt.schedule(RETENTION_CRON, RETENTION_WORKFLOW);
}
