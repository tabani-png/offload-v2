-- m3-01-ingest-batches. Upload consent (DATA_MODEL.md section 3, `consents`, retention class R-gov) and the tenant list for
-- the retention workflow.

-- One row per consent a member gave from a device; withdrawing sets withdrawn_at. Ingest accepts observations only
-- while the member has a row for the current notice version with no withdrawn_at. At most one open row per member
-- and notice (a newer version supersedes the older one by withdrawing it in the same transaction).
create table consents (
  tenant_id uuid not null references tenants(id),
  id uuid not null,
  member_id uuid not null,
  device_id uuid not null,
  notice_id text not null check (notice_id ~ '^[a-z][a-z0-9-]{0,63}$'),
  notice_version text not null check (notice_version ~ '^[A-Za-z0-9_.-]{1,32}$'),
  given_at timestamptz not null default now(),
  withdrawn_at timestamptz,
  primary key (tenant_id, id),
  foreign key (tenant_id, member_id) references members (tenant_id, id),
  foreign key (tenant_id, device_id) references devices (tenant_id, id)
);
create unique index consents_open on consents (tenant_id, member_id, notice_id) where withdrawn_at is null;

select apply_tenant_rls('public.consents'::regclass);
grant select, insert, update on consents to offload_app;

-- The retention workflow works one tenant at a time (it writes purge_log per tenant), so it needs the tenant ids.
grant execute on function jobs_list_tenants() to offload_retention;
