-- m1-03-tenancy-rls. Helper functions every later migration uses to put a table behind the tenant wall and the member
-- wall (ADR 0013), and the append-only trigger (DATA_MODEL.md section 1). Run as offload_migrator, which owns them.
-- None of these is executable by the runtime roles.

-- Tenant wall: ENABLE + FORCE RLS and policy tenant_isolation. `tenants` itself uses its `id` column.
create function apply_tenant_rls(t regclass) returns void
language plpgsql set search_path = public as $$
declare
  col text := case when t = 'public.tenants'::regclass then 'id' else 'tenant_id' end;
begin
  execute format('alter table %s enable row level security', t);
  execute format('alter table %s force row level security', t);
  if not exists (select 1 from pg_policy where polrelid = t and polname = 'tenant_isolation') then
    execute format(
      'create policy tenant_isolation on %s using (%I = nullif(current_setting(''app.tenant_id'', true), '''')::uuid) '
      'with check (%I = nullif(current_setting(''app.tenant_id'', true), '''')::uuid)', t, col, col);
  end if;
end $$;

-- Member wall (restrictive): C1, C2 and C6 tables. The table list of record is MEMBER_ISOLATED_TABLES in
-- packages/db/src/tables.ts; a test checks that it equals the set of tables carrying this policy.
create function apply_member_isolation(t regclass) returns void
language plpgsql set search_path = public as $$
begin
  if not exists (select 1 from pg_policy where polrelid = t and polname = 'member_isolation') then
    execute format(
      'create policy member_isolation on %s as restrictive using (member_id = nullif(current_setting(''app.member_id'', true), '''')::uuid '
      'or current_setting(''app.member_scope'', true) = ''tenant'')', t);
  end if;
end $$;

-- Append-only set: refuses UPDATE, DELETE and TRUNCATE for every role except offload_retention. Grants narrow
-- offload_retention further (DELETE only). item_journal and friends join in M2 with this same function.
create function refuse_mutation() returns trigger
language plpgsql set search_path = public as $$
begin
  if current_user = 'offload_retention' then
    if tg_level = 'STATEMENT' then return null; end if;
    if tg_op = 'DELETE' then return old; end if;
    return new;
  end if;
  raise exception 'append_only: % on % is refused', tg_op, tg_table_name using errcode = '42501';
end $$;

create function apply_append_only(t regclass) returns void
language plpgsql set search_path = public as $$
begin
  execute format('create trigger append_only_rows before update or delete on %s for each row execute function refuse_mutation()', t);
  execute format('create trigger append_only_truncate before truncate on %s for each statement execute function refuse_mutation()', t);
end $$;

revoke all on function apply_tenant_rls(regclass), apply_member_isolation(regclass), apply_append_only(regclass),
  refuse_mutation() from public;
