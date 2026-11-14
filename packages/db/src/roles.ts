import type { ClientBase } from "pg";

/** Database roles, ADR 0013. */
export const ROLES = {
  /** Owns every table and function; runs migrations; the owner of the SECURITY DEFINER resolvers. */
  migrator: "offload_migrator",
  /** The application. Not an owner, no BYPASSRLS, no DELETE or UPDATE on the append-only set. */
  app: "offload_app",
  /** Deletes expired rows and drops expired partitions only. */
  retention: "offload_retention",
  /** Cross-tenant jobs: EXECUTE on jobs_list_tenants() and outbox_claim(limit) only. */
  jobs: "offload_jobs",
} as const;

/**
 * Creates the four roles if they are missing and lets offload_migrator create objects in this database. Run once per
 * cluster and database by an administrator (superuser: BYPASSRLS needs one), before `migrate`. Idempotent and safe to
 * run concurrently. Passwords are set by the operator outside this code.
 *
 * offload_migrator has BYPASSRLS because every table forces RLS, and the resolver functions it owns run before a
 * tenant is known.
 */
export async function bootstrapRoles(admin: ClientBase): Promise<void> {
  const me = (await admin.query("select current_user as u")).rows[0].u as string;
  if ((Object.values(ROLES) as string[]).includes(me)) {
    throw new Error(`bootstrapRoles must run as an administrator, not as ${me}: it sets the attributes of that role`);
  }
  const attrs: Record<string, string> = {
    [ROLES.migrator]: "login nosuperuser nocreatedb nocreaterole bypassrls",
    [ROLES.app]: "login nosuperuser nocreatedb nocreaterole nobypassrls",
    [ROLES.retention]: "login nosuperuser nocreatedb nocreaterole nobypassrls",
    [ROLES.jobs]: "login nosuperuser nocreatedb nocreaterole nobypassrls",
  };
  for (const [role, a] of Object.entries(attrs)) {
    await admin.query(
      `do $$ begin
         if not exists (select 1 from pg_roles where rolname = '${role}') then
           begin create role ${role}; exception when duplicate_object or unique_violation then null; end;
         end if;
       end $$`,
    );
    await admin.query(`alter role ${role} ${a}`);
  }
  const db = (await admin.query("select current_database() as d")).rows[0].d as string;
  await admin.query(`grant connect, create on database "${db.replace(/"/g, '""')}" to ${ROLES.migrator}`);
  await admin.query(`grant usage, create on schema public to ${ROLES.migrator}`);
  for (const r of [ROLES.app, ROLES.retention, ROLES.jobs]) {
    await admin.query(`grant connect on database "${db.replace(/"/g, '""')}" to ${r}`);
    await admin.query(`grant usage on schema public to ${r}`);
  }
}
