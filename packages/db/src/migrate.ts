import { readFileSync, readdirSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { sha256Hex } from "@offload/contracts";
import type { ClientBase } from "pg";

/** Plain SQL migrations, `NNNN_name.sql`, applied in order and checksummed in `schema_migrations`. */
export const MIGRATIONS_DIR = fileURLToPath(new URL("../migrations", import.meta.url));

export class MigrationChecksumError extends Error {
  readonly code = "migration_checksum";
  constructor(readonly version: string) {
    super(`migration ${version} changed after it was applied (checksum differs)`);
    this.name = "MigrationChecksumError";
  }
}

const FILE_RE = /^(\d{4})_([a-z0-9_]+)\.sql$/;

/**
 * Applies pending migrations in version order, each in its own transaction, as the connected role (offload_migrator).
 * Refuses to run when an applied migration's file changed. Returns the versions it applied.
 */
export async function migrate(client: ClientBase, opts: { dir?: string } = {}): Promise<string[]> {
  const dir = opts.dir ?? MIGRATIONS_DIR;
  const files = readdirSync(dir).filter((f) => FILE_RE.test(f)).sort();
  const seen = new Set<string>();
  for (const f of files) {
    const v = f.slice(0, 4);
    if (seen.has(v)) throw new Error(`two migrations share version ${v}`);
    seen.add(v);
  }
  await client.query("select pg_advisory_lock(hashtextextended('offload:migrate', 0))");
  try {
    await client.query(
      `create table if not exists schema_migrations (
         version text primary key, name text not null, checksum text not null, applied_at timestamptz not null default clock_timestamp())`,
    );
    const applied = new Map<string, string>(
      (await client.query("select version, checksum from schema_migrations")).rows.map((r) => [r.version as string, r.checksum as string]),
    );
    const plan: { version: string; name: string; sql: string; checksum: string }[] = [];
    for (const f of files) {
      const m = FILE_RE.exec(f)!;
      const sql = readFileSync(`${dir}/${f}`, "utf8");
      const checksum = sha256Hex(sql);
      const have = applied.get(m[1]!);
      if (have !== undefined) {
        if (have !== checksum) throw new MigrationChecksumError(m[1]!);
        continue;
      }
      plan.push({ version: m[1]!, name: m[2]!, sql, checksum });
    }
    const done: string[] = [];
    for (const p of plan) {
      await client.query("begin");
      try {
        await client.query(p.sql);
        await client.query("insert into schema_migrations (version, name, checksum) values ($1, $2, $3)", [p.version, p.name, p.checksum]);
        await client.query("commit");
      } catch (err) {
        await client.query("rollback").catch(() => {});
        throw err;
      }
      done.push(p.version);
    }
    return done;
  } finally {
    await client.query("select pg_advisory_unlock(hashtextextended('offload:migrate', 0))").catch(() => {});
  }
}
