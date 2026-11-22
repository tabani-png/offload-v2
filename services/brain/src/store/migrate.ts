// Applies services/brain/sql/*.sql in order into one schema. packages/db's migration runner adopts these files later
// (checksums in schema_migrations, roles from m1-03); until then this keeps the brain's tables testable.
import type { SQL } from "bun";
import { readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { ident } from "./tenant.ts";

export const MIGRATIONS_DIR = join(import.meta.dir, "../../sql");

/** The member-isolated (MI) tables this module creates; packages/db appends them to its MEMBER_ISOLATED_TABLES. */
export const MEMBER_ISOLATED_TABLES = [
  "profiles", "goals", "task_ledger", "episodes", "propositions", "day_records", "week_records", "month_records",
  "quarter_records", "figure_index", "review_answers", "opportunities", "fixes",
] as const;

export function migrationFiles(): string[] {
  return readdirSync(MIGRATIONS_DIR).filter((f) => /^\d{4}_[a-z0-9_]+\.sql$/.test(f)).sort();
}

/** Applies every migration into `schema`, with `offload_app` replaced by `appRole`. Returns the files applied. */
export async function applyUserModelMigrations(sql: SQL, opts: { schema: string; appRole: string }): Promise<string[]> {
  const schema = ident(opts.schema);
  const role = ident(opts.appRole);
  const files = migrationFiles();
  for (const f of files) {
    const text = readFileSync(join(MIGRATIONS_DIR, f), "utf8").replace(/\boffload_app\b/g, role);
    await sql.begin(async (tx) => {
      await tx.unsafe(`SET LOCAL search_path TO ${schema}`);
      await tx.unsafe(text);
    });
  }
  return files;
}
