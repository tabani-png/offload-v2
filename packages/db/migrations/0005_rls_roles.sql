-- m1-03-tenancy-rls. Tenant wall, member wall, grants, resolver functions and cross-tenant job functions (ADR 0013).
-- The roles themselves are created once by bootstrapRoles() (packages/db/src/roles.ts), run by an admin.

-- Tenant wall on every table in schema public that holds tenant data, partitions included.
do $$
declare r record;
begin
  for r in
    select c.oid::regclass as t from pg_class c join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relkind in ('r', 'p')
      and (c.relname = 'tenants' or exists (
        select 1 from pg_attribute a where a.attrelid = c.oid and a.attname = 'tenant_id' and not a.attisdropped))
  loop
    perform apply_tenant_rls(r.t);
  end loop;
end $$;

-- Member wall: MEMBER_ISOLATED_TABLES (packages/db/src/tables.ts), partitions included.
do $$
declare r record;
begin
  for r in
    select c.oid::regclass as t from pg_class c join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relkind in ('r', 'p')
      and (c.relname in ('observations', 'observation_texts', 'imports', 'exclusions')
        or c.relname like 'observations\_%' or c.relname like 'observation\_texts\_%')
  loop
    perform apply_member_isolation(r.t);
  end loop;
end $$;

-- offload_app: ordinary rights on tenant tables; INSERT and SELECT only on the append-only set; nothing on
-- schema_migrations; read-only license_state. Partitions are reached through their parent only.
grant select, insert, update, delete on
  tenants, workspaces, members, workspace_members, sessions, devices, device_nonces, device_enrollment_codes,
  personal_access_tokens, pseudonym_key_wraps, idempotency_keys, magic_links, exclusions, imports, ingest_batches,
  observations, observation_texts, purge_requests, events_outbox, outbox_deliveries
  to offload_app;
grant select, insert on audit_events, audit_anchors, purge_log to offload_app;
grant select on license_state to offload_app;

-- offload_retention: deletes expired rows (the retention workflow, m3-01, picks them from config TTLs) and drops
-- expired partitions through retention_drop_partition(). Writes purge_log and an anchor before deleting audit rows.
grant select, delete on
  observations, observation_texts, ingest_batches, idempotency_keys, sessions, device_nonces,
  device_enrollment_codes, magic_links, events_outbox, outbox_deliveries, audit_events, audit_anchors, purge_log
  to offload_retention;
grant insert on purge_log, audit_anchors to offload_retention;
grant execute on function ensure_partitions(date, integer) to offload_retention;

-- Drops one daily capture partition whose whole range is before `cutoff`, and only if cutoff is in the past.
create function retention_drop_partition(part regclass, cutoff date) returns void
language plpgsql security definer set search_path = pg_catalog, public, pg_temp as $$
declare
  parent text;
  upper_bound date;
begin
  if cutoff is null or cutoff >= current_date then
    raise exception 'retention_drop_partition: cutoff must be in the past' using errcode = '22023';
  end if;
  select p.relname, (regexp_match(pg_get_expr(c.relpartbound, c.oid), 'TO \(''([0-9-]+)''\)'))[1]::date
    into parent, upper_bound
    from pg_class c join pg_inherits i on i.inhrelid = c.oid join pg_class p on p.oid = i.inhparent
    where c.oid = part;
  if parent is null or parent not in ('observations', 'observation_texts') or upper_bound is null then
    raise exception 'retention_drop_partition: not a daily capture partition' using errcode = '22023';
  end if;
  if upper_bound > cutoff then
    raise exception 'retention_drop_partition: partition is not expired' using errcode = '22023';
  end if;
  execute format('drop table %s', part);
end $$;
revoke all on function retention_drop_partition(regclass, date) from public;
grant execute on function retention_drop_partition(regclass, date) to offload_retention;

-- Bootstrap resolvers: SECURITY DEFINER, owned by offload_migrator, ids only, no row for an unknown key, a deleted
-- tenant, or a departed or frozen member. search_path ends in pg_temp so a temp table cannot shadow a table.
create function auth_resolve_identity(idp_subject text)
returns table (tenant_id uuid, member_id uuid)
language sql stable security definer set search_path = pg_catalog, public, pg_temp as $$
  select m.tenant_id, m.id from members m join tenants t on t.id = m.tenant_id
  where m.idp_subject = auth_resolve_identity.idp_subject and t.deleted_at is null
    and m.state not in ('departed', 'frozen')
$$;

create function auth_resolve_session(token_sha256 text)
returns table (tenant_id uuid, member_id uuid, tenant_role text, expires_at timestamptz, last_seen_at timestamptz)
language sql stable security definer set search_path = pg_catalog, public, pg_temp as $$
  select s.tenant_id, s.member_id, m.tenant_role, s.expires_at, s.last_seen_at
  from sessions s join members m on m.tenant_id = s.tenant_id and m.id = s.member_id
  join tenants t on t.id = s.tenant_id
  where s.token_sha256 = auth_resolve_session.token_sha256 and s.revoked_at is null and t.deleted_at is null
    and m.state not in ('departed', 'frozen')
$$;

create function auth_resolve_device(device_id uuid)
returns table (tenant_id uuid, member_id uuid, revoked_at timestamptz)
language sql stable security definer set search_path = pg_catalog, public, pg_temp as $$
  select d.tenant_id, d.member_id, d.revoked_at from devices d join tenants t on t.id = d.tenant_id
  join members m on m.tenant_id = d.tenant_id and m.id = d.member_id
  where d.id = auth_resolve_device.device_id and t.deleted_at is null and m.state not in ('departed', 'frozen')
$$;

create function auth_resolve_enrollment_code(code_sha256 text)
returns table (tenant_id uuid, member_id uuid, code_challenge text, redirect_uri text, expires_at timestamptz,
  used_at timestamptz)
language sql stable security definer set search_path = pg_catalog, public, pg_temp as $$
  select c.tenant_id, c.member_id, c.code_challenge, c.redirect_uri, c.expires_at, c.used_at
  from device_enrollment_codes c join tenants t on t.id = c.tenant_id
  join members m on m.tenant_id = c.tenant_id and m.id = c.member_id
  where c.code_sha256 = auth_resolve_enrollment_code.code_sha256 and t.deleted_at is null
    and m.state not in ('departed', 'frozen')
$$;

create function auth_resolve_pat(token_sha256 text)
returns table (tenant_id uuid, member_id uuid, scopes text[], revoked_at timestamptz)
language sql stable security definer set search_path = pg_catalog, public, pg_temp as $$
  select p.tenant_id, p.member_id, p.scopes, p.revoked_at from personal_access_tokens p
  join tenants t on t.id = p.tenant_id
  join members m on m.tenant_id = p.tenant_id and m.id = p.member_id
  where p.token_sha256 = auth_resolve_pat.token_sha256 and t.deleted_at is null and m.state not in ('departed', 'frozen')
$$;

-- Cross-tenant jobs: ids only; the job then works per tenant through withTenant.
create function jobs_list_tenants()
returns table (tenant_id uuid)
language sql stable security definer set search_path = pg_catalog, public, pg_temp as $$
  select t.id from tenants t where t.deleted_at is null order by t.id
$$;

-- Claims up to `lim` undelivered outbox events for the dispatcher by inserting its outbox_deliveries row.
create function outbox_claim("limit" integer)
returns table (tenant_id uuid, id uuid)
language sql volatile security definer set search_path = pg_catalog, public, pg_temp as $$
  with c as (
    select e.tenant_id, e.id from events_outbox e
    where not exists (select 1 from outbox_deliveries d
      where d.tenant_id = e.tenant_id and d.event_id = e.id and d.consumer = 'workflow:outbox_dispatch')
    order by e.created_at, e.id
    limit least(greatest(coalesce(outbox_claim."limit", 0), 0), 1000)
    for update of e skip locked
  ), ins as (
    insert into outbox_deliveries (tenant_id, event_id, consumer, attempts)
    select c.tenant_id, c.id, 'workflow:outbox_dispatch', 0 from c
    on conflict do nothing
    returning outbox_deliveries.tenant_id, outbox_deliveries.event_id
  )
  select ins.tenant_id, ins.event_id from ins
$$;

revoke all on function auth_resolve_identity(text), auth_resolve_session(text), auth_resolve_device(uuid),
  auth_resolve_enrollment_code(text), auth_resolve_pat(text), jobs_list_tenants(), outbox_claim(integer) from public;
grant execute on function auth_resolve_identity(text), auth_resolve_session(text), auth_resolve_device(uuid),
  auth_resolve_enrollment_code(text), auth_resolve_pat(text) to offload_app;
grant execute on function jobs_list_tenants(), outbox_claim(integer) to offload_jobs;

-- Functions created later by offload_migrator are not executable by PUBLIC unless granted.
alter default privileges for role offload_migrator revoke execute on functions from public;
