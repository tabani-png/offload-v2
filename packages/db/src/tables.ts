/**
 * Table lists of record for the walls in ADR 0013. Tests compare them with the policies in the database.
 */

/** C1, C2 and C6 tables with the restrictive `member_isolation` policy (DATA_MODEL.md, tables marked MI). Later
 * slices append to this list in the same commit as the migration that adds the table. */
export const MEMBER_ISOLATED_TABLES: readonly string[] = ["observations", "observation_texts", "imports", "exclusions"];

/** The append-only set (DATA_MODEL.md section 1): trigger `refuse_mutation()`, offload_app has INSERT and SELECT
 * only. item_journal, item_journal_transitions, budget_entries and approvals join in M2. */
export const APPEND_ONLY_TABLES: readonly string[] = ["audit_events", "audit_anchors", "purge_log"];

/** Global tables in schema public without RLS: they hold no tenant data. Schema `durable` is allowlisted by name. */
export const RLS_GLOBAL_ALLOWLIST: readonly string[] = ["schema_migrations", "license_state", "magic_links"];
