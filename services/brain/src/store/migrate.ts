// Applies services/brain/sql/*.sql in order into one schema. packages/db's migration runner adopts these files later
// (checksums in schema_migrations, roles from m1-03); until then this keeps the brain's tables testable.
import type { SQL } from "bun";

/** The member-isolated (MI) tables this module creates; packages/db appends them to its MEMBER_ISOLATED_TABLES. */
export const MEMBER_ISOLATED_TABLES = [
  "profiles", "goals", "task_ledger", "episodes", "propositions", "day_records", "week_records", "month_records",
  "quarter_records", "figure_index", "review_answers", "opportunities",
] as const;

export async function applyUserModelMigrations(_sql: SQL, _opts: { schema: string; appRole: string }): Promise<string[]> {
  throw new Error("not implemented");
}
