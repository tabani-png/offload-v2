import { Pool } from "pg";
import { databaseUrl, roleUrl, testRolePassword } from "../pg.ts";

/** The broker's database role (migration 0201). Cluster-wide, like the roles in ROLES. */
export const BROKER_ROLE = "offload_broker";

/**
 * Creates the offload_broker login role and gives it its test password. In a real deployment this is an administrator's
 * job (the migrator cannot create roles). Call it BEFORE freshDatabase or pgTenantFixture, so migration 0201 finds the
 * role and grants to it.
 */
export async function ensureBrokerRole(): Promise<void> {
  const admin = new Pool({ connectionString: databaseUrl(), max: 1 });
  try {
    await admin.query(
      `do $$ begin
         if not exists (select 1 from pg_roles where rolname = '${BROKER_ROLE}') then
           begin create role ${BROKER_ROLE} login nosuperuser nocreatedb nocreaterole nobypassrls;
           exception when duplicate_object or unique_violation then null; end;
         end if;
       end $$`,
    );
    await admin.query(`alter role ${BROKER_ROLE} login nosuperuser nocreatedb nocreaterole nobypassrls password '${testRolePassword(BROKER_ROLE)}'`);
  } finally {
    await admin.end();
  }
}

/** A pool that connects as offload_broker. */
export function brokerPool(size = 4): Pool {
  return new Pool({ connectionString: roleUrl(BROKER_ROLE), max: size });
}
