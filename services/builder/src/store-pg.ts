// BuildStore on Postgres 17 with Bun's built-in SQL (no new dependency). Every method is one short transaction that
// sets app.tenant_id first, so it works under forced tenant RLS as a non-owner role (ADR 0013); no network I/O happens
// inside a transaction. The build lock is the partial unique index builds_one_live_per_brief; reservations take a row
// lock on the build (ADR 0030); budget_entries are append-only and idempotent by key (ADR 0031).
import type { SQL } from "bun";
import { join } from "node:path";
import { staleNote, BuildConflict, type AttemptRow, type BuildPatch, type BuildRow, type BuildStore, type NewBuild, type Reservation, type Settlement, type Stage } from "./store.ts";

export const MIGRATIONS = ["0001_builder.sql"];

/** Applies services/builder/sql/* in order to the connection's search_path schema. */
export async function migrate(sql: SQL): Promise<void> {
  for (const f of MIGRATIONS) await sql.unsafe(await Bun.file(join(import.meta.dir, "..", "sql", f)).text());
}

const LIVE = ["queued", "building", "verifying", "fanning_out", "repairing"];
const usd = (n: number) => (n / 10_000).toFixed(4);
const usd4 = (v: unknown) => Math.round(Number(v) * 10_000);
const ms = (v: unknown) => (v === null || v === undefined ? null : new Date(v as string | Date).getTime());
const jsonb = (v: unknown) => JSON.stringify(v);
const asJson = <T>(v: unknown): T => (typeof v === "string" ? (JSON.parse(v) as T) : (v as T));
type Tx = SQL;

function rowToBuild(r: Record<string, unknown>): BuildRow {
  return {
    tenant_id: r["tenant_id"] as string,
    id: r["id"] as string,
    fix_id: r["fix_id"] as string,
    brief_id: r["brief_id"] as string,
    approval_id: (r["approval_id"] as string | null) ?? null,
    state: r["state"] as BuildRow["state"],
    cap_usd4: usd4(r["cap_usd"]),
    spent_usd4: usd4(r["spent_usd"]),
    fanout_workers: Number(r["fanout_workers"]),
    infra_retries: Number(r["infra_retries"]),
    bound_hashes: asJson<Record<string, string>>(r["bound_hashes"]),
    stages: asJson<Stage[]>(r["stages"]),
    winner_attempt_id: (r["winner_attempt_id"] as string | null) ?? null,
    artifact_sha256: (r["artifact_sha256"] as string | null) ?? null,
    receipt_hash: (r["receipt_hash"] as string | null) ?? null,
    definition_hash: (r["definition_hash"] as string | null) ?? null,
    receipt: r["receipt"] === null || r["receipt"] === undefined ? null : asJson<unknown>(r["receipt"]),
    created_at: ms(r["created_at"])!,
    heartbeat_at: ms(r["heartbeat_at"])!,
    started_at: ms(r["started_at"]),
    ended_at: ms(r["ended_at"]),
    deployed_at: ms(r["deployed_at"]),
  };
}

function rowToAttempt(r: Record<string, unknown>): AttemptRow {
  return {
    tenant_id: r["tenant_id"] as string,
    id: r["id"] as string,
    build_id: r["build_id"] as string,
    ordinal: Number(r["ordinal"]),
    sandbox_provider: r["sandbox_provider"] as string,
    sandbox_id: (r["sandbox_id"] as string | null) ?? null,
    outcome: r["outcome"] as AttemptRow["outcome"],
    spent_usd4: usd4(r["spent_usd"]),
    tries: Number(r["tries"]),
    turns: Number(r["turns"]),
    frozen_pass: (r["frozen_pass"] as boolean | null) ?? null,
    held_out_pass: (r["held_out_pass"] as boolean | null) ?? null,
    check_groups: asJson<AttemptRow["check_groups"]>(r["check_groups"]),
    artifact_sha256: (r["artifact_sha256"] as string | null) ?? null,
    artifact_bytes: Number(r["artifact_bytes"]),
    artifact_files: asJson<string[]>(r["artifact_files"]),
    note: r["note"] as string,
  };
}

export class PgBuildStore implements BuildStore {
  constructor(private readonly sql: SQL) {}

  private tx<T>(tenant_id: string, f: (tx: Tx) => Promise<T>): Promise<T> {
    return this.sql.begin(async (tx) => {
      await tx`SELECT set_config('app.tenant_id', ${tenant_id}, true)`;
      return f(tx as unknown as Tx);
    }) as Promise<T>;
  }

  private async read(tx: Tx, tenant_id: string, id: string, lock = false): Promise<BuildRow | null> {
    const rows = lock
      ? await tx`SELECT b.*, r.receipt FROM builds b LEFT JOIN build_receipts r ON r.tenant_id = b.tenant_id AND r.build_id = b.id WHERE b.tenant_id = ${tenant_id} AND b.id = ${id} FOR UPDATE OF b`
      : await tx`SELECT b.*, r.receipt FROM builds b LEFT JOIN build_receipts r ON r.tenant_id = b.tenant_id AND r.build_id = b.id WHERE b.tenant_id = ${tenant_id} AND b.id = ${id}`;
    return rows.length === 0 ? null : rowToBuild(rows[0] as Record<string, unknown>);
  }

  async insertQueued(b: NewBuild, now: number, stale_after_ms: number): Promise<BuildRow> {
    try {
      return await this.tx(b.tenant_id, async (tx) => {
        const live = await tx`SELECT id, heartbeat_at, stages FROM builds WHERE tenant_id = ${b.tenant_id} AND brief_id = ${b.brief_id} AND state IN ${tx(LIVE)} FOR UPDATE`;
        for (const x of live as Array<Record<string, unknown>>) {
          if (now - ms(x["heartbeat_at"])! <= stale_after_ms) throw new BuildConflict("already_running");
          const stages = [...asJson<Stage[]>(x["stages"]), { name: "recovered", state: "failed", started_at: now, ended_at: now, note: staleNote }];
          await tx`UPDATE builds SET state = 'infra_failed', ended_at = ${new Date(now)}, heartbeat_at = ${new Date(now)}, stages = ${jsonb(stages)}::text::jsonb WHERE tenant_id = ${b.tenant_id} AND id = ${x["id"] as string}`;
        }
        await tx`INSERT INTO builds (tenant_id, id, fix_id, brief_id, state, cap_usd, fanout_workers, bound_hashes, created_at, heartbeat_at)
                 VALUES (${b.tenant_id}, ${b.id}, ${b.fix_id}, ${b.brief_id}, 'queued', ${usd(b.cap_usd4)}::numeric, ${b.fanout_workers}, ${jsonb(b.bound_hashes)}::text::jsonb, ${new Date(now)}, ${new Date(now)})`;
        return (await this.read(tx, b.tenant_id, b.id))!;
      });
    } catch (e) {
      if (e instanceof BuildConflict) throw e;
      if ((e as { errno?: string }).errno === "23505") throw new BuildConflict("already_running");
      throw e;
    }
  }

  async heldOutUsed(tenant_id: string, brief_id: string, held_out_hash: string): Promise<boolean> {
    return this.tx(tenant_id, async (tx) => {
      const r = await tx`SELECT EXISTS (SELECT 1 FROM builds b WHERE b.tenant_id = ${tenant_id} AND b.brief_id = ${brief_id} AND b.bound_hashes->>'held_out_hash' = ${held_out_hash}
                           AND EXISTS (SELECT 1 FROM worker_attempts a WHERE a.tenant_id = b.tenant_id AND a.build_id = b.id)) AS used`;
      return (r[0] as { used: boolean }).used === true;
    });
  }

  async get(tenant_id: string, id: string): Promise<BuildRow | null> {
    return this.tx(tenant_id, (tx) => this.read(tx, tenant_id, id));
  }

  async update(tenant_id: string, id: string, patch: BuildPatch, now: number): Promise<BuildRow> {
    return this.tx(tenant_id, async (tx) => {
      const cur = await this.read(tx, tenant_id, id, true);
      if (cur === null) throw new Error("no such build");
      const n = { ...cur, ...patch };
      const d = (v: number | null) => (v === null ? null : new Date(v));
      await tx`UPDATE builds SET approval_id = ${n.approval_id}, state = ${n.state}, stages = ${jsonb(n.stages)}::text::jsonb, winner_attempt_id = ${n.winner_attempt_id},
                 artifact_sha256 = ${n.artifact_sha256}, receipt_hash = ${n.receipt_hash}, definition_hash = ${n.definition_hash}, infra_retries = ${n.infra_retries},
                 started_at = ${d(n.started_at)}, ended_at = ${d(n.ended_at)}, heartbeat_at = ${new Date(now)}
               WHERE tenant_id = ${tenant_id} AND id = ${id}`;
      if (patch.receipt !== undefined && patch.receipt !== null && n.receipt_hash !== null) {
        await tx`INSERT INTO build_receipts (tenant_id, build_id, receipt, receipt_hash) VALUES (${tenant_id}, ${id}, ${jsonb(patch.receipt)}::text::jsonb, ${n.receipt_hash})
                 ON CONFLICT (tenant_id, build_id) DO NOTHING`;
      }
      return (await this.read(tx, tenant_id, id))!;
    });
  }

  async putAttempt(a: AttemptRow): Promise<void> {
    await this.tx(a.tenant_id, async (tx) => {
      await tx`INSERT INTO worker_attempts (tenant_id, id, build_id, ordinal, sandbox_provider, sandbox_id, outcome, spent_usd, tries, turns, frozen_pass, held_out_pass, check_groups, artifact_sha256, artifact_bytes, artifact_files, note)
               VALUES (${a.tenant_id}, ${a.id}, ${a.build_id}, ${a.ordinal}, ${a.sandbox_provider}, ${a.sandbox_id}, ${a.outcome}, ${usd(a.spent_usd4)}::numeric, ${a.tries}, ${a.turns}, ${a.frozen_pass}, ${a.held_out_pass},
                       ${jsonb(a.check_groups)}::text::jsonb, ${a.artifact_sha256}, ${a.artifact_bytes}, ${jsonb(a.artifact_files)}::text::jsonb, ${a.note})
               ON CONFLICT (tenant_id, id) DO UPDATE SET sandbox_id = EXCLUDED.sandbox_id, outcome = EXCLUDED.outcome, spent_usd = EXCLUDED.spent_usd, tries = EXCLUDED.tries, turns = EXCLUDED.turns,
                 frozen_pass = EXCLUDED.frozen_pass, held_out_pass = EXCLUDED.held_out_pass, check_groups = EXCLUDED.check_groups, artifact_sha256 = EXCLUDED.artifact_sha256,
                 artifact_bytes = EXCLUDED.artifact_bytes, artifact_files = EXCLUDED.artifact_files, note = EXCLUDED.note`;
    });
  }

  async attempts(tenant_id: string, build_id: string): Promise<AttemptRow[]> {
    return this.tx(tenant_id, async (tx) => {
      const rows = await tx`SELECT * FROM worker_attempts WHERE tenant_id = ${tenant_id} AND build_id = ${build_id} ORDER BY ordinal, id`;
      return (rows as Array<Record<string, unknown>>).map(rowToAttempt);
    });
  }

  async reserve(r: Reservation, now: number): Promise<boolean> {
    if (r.usd4 <= 0) return false;
    return this.tx(r.tenant_id, async (tx) => {
      const b = await tx`SELECT spent_usd FROM builds WHERE tenant_id = ${r.tenant_id} AND id = ${r.build_id} FOR UPDATE`;
      if (b.length === 0) return false;
      const open = await tx`SELECT coalesce(sum(reserved_usd), 0) AS open FROM budget_reservations WHERE tenant_id = ${r.tenant_id} AND build_id = ${r.build_id} AND settled_at IS NULL`;
      if (usd4((b[0] as { spent_usd: string }).spent_usd) + usd4((open[0] as { open: string }).open) + r.usd4 > r.ceiling_usd4) return false;
      await tx`INSERT INTO budget_reservations (tenant_id, build_id, attempt_id, call_id, kind, reserved_usd, created_at)
               VALUES (${r.tenant_id}, ${r.build_id}, ${r.attempt_id}, ${r.call_id}, ${r.kind}, ${usd(r.usd4)}::numeric, ${new Date(now)})`;
      return true;
    });
  }

  async settle(s: Settlement, now: number): Promise<void> {
    await this.tx(s.tenant_id, async (tx) => {
      await tx`SELECT 1 FROM builds WHERE tenant_id = ${s.tenant_id} AND id = ${s.build_id} FOR UPDATE`;
      const ins = await tx`INSERT INTO budget_entries (tenant_id, idempotency_key, scope, scope_id, model, sandbox_seconds, usd, at)
                           VALUES (${s.tenant_id}, ${s.idempotency_key}, ${s.scope}, ${s.build_id}, ${s.model ?? null}, ${s.sandbox_seconds ?? null}, ${usd(s.usd4)}::numeric, ${new Date(now)})
                           ON CONFLICT (tenant_id, idempotency_key) DO NOTHING RETURNING id`;
      if (ins.length > 0 && s.scope === "build") await tx`UPDATE builds SET spent_usd = spent_usd + ${usd(s.usd4)}::numeric WHERE tenant_id = ${s.tenant_id} AND id = ${s.build_id}`;
      await tx`UPDATE budget_reservations SET settled_at = ${new Date(now)} WHERE tenant_id = ${s.tenant_id} AND build_id = ${s.build_id} AND call_id = ${s.call_id} AND settled_at IS NULL`;
    });
  }

  async markDeployed(tenant_id: string, id: string, now: number): Promise<boolean> {
    return this.tx(tenant_id, async (tx) => {
      const r = await tx`UPDATE builds SET deployed_at = ${new Date(now)} WHERE tenant_id = ${tenant_id} AND id = ${id} AND state = 'ready' AND deployed_at IS NULL RETURNING id`;
      return r.length === 1;
    });
  }
}
