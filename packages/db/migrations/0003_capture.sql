-- m1-03-tenancy-rls. Capture tables, DATA_MODEL.md section 5. Ingest itself arrives in m3-01.
-- observations and observation_texts are PARTITION BY RANGE (day) with a DEFAULT partition; `day` is the UTC date of
-- `ts` (for imports, of ingest), set by the server. Daily partitions come from ensure_partitions() below.

create table exclusions (
  tenant_id uuid not null references tenants(id),
  member_id uuid not null,
  id uuid not null,
  kind text not null check (kind in ('bundle_id', 'host', 'title_contains')),
  value text not null,
  source text not null check (source in ('builtin', 'user')),
  primary key (tenant_id, member_id, id),
  foreign key (tenant_id, member_id) references members (tenant_id, id)
);

create table imports (
  tenant_id uuid not null references tenants(id),
  member_id uuid not null,
  id uuid not null,
  source_kind text not null check (source_kind in ('screenwatch', 'screenshots', 'videos')),
  first_day date,
  last_day date,
  created_at timestamptz not null default now(),
  wiped_at timestamptz,
  primary key (tenant_id, member_id, id),
  foreign key (tenant_id, member_id) references members (tenant_id, id)
);

create table ingest_batches (
  tenant_id uuid not null references tenants(id),
  device_id uuid not null,
  seq bigint not null,
  kind text not null,
  body_sha256 text not null check (body_sha256 ~ '^[0-9a-f]{64}$'),
  object_count integer not null check (object_count >= 0),
  received_at timestamptz not null default now(),
  receipt jsonb,
  primary key (tenant_id, device_id, seq),
  foreign key (tenant_id, device_id) references devices (tenant_id, id)
);

create table observations (
  tenant_id uuid not null references tenants(id),
  device_id uuid not null,
  object_id text not null check (object_id ~ '^[0-7][0-9A-HJKMNP-TV-Z]{25}$'),
  day date not null,
  member_id uuid not null,
  ts timestamptz not null,
  kind text not null check (kind in ('focus', 'idle_start', 'idle_end', 'input_counts', 'pause', 'resume', 'permission_change')),
  app_bundle_id text,
  app_name text,
  title text,
  host text,
  doc text,
  keys integer,
  clicks integer,
  reason text,
  perm jsonb,
  source text not null default 'live' check (source in ('live', 'import')),
  import_id uuid,
  primary key (tenant_id, device_id, object_id, day),
  foreign key (tenant_id, device_id) references devices (tenant_id, id),
  foreign key (tenant_id, member_id) references members (tenant_id, id)
) partition by range (day);
create index observations_member_ts on observations (tenant_id, member_id, ts);
create table observations_default partition of observations default;

create table observation_texts (
  tenant_id uuid not null references tenants(id),
  device_id uuid not null,
  object_id text not null check (object_id ~ '^[0-7][0-9A-HJKMNP-TV-Z]{25}$'),
  day date not null,
  member_id uuid not null,
  ts timestamptz not null,
  text text not null check (char_length(text) <= 8000),
  text_hash text not null check (text_hash ~ '^[0-9a-f]{64}$'),
  text_source text not null check (text_source in ('ax', 'ocr')),
  app_bundle_id text,
  source text not null default 'live' check (source in ('live', 'import')),
  import_id uuid,
  primary key (tenant_id, device_id, object_id, day),
  foreign key (tenant_id, device_id) references devices (tenant_id, id),
  foreign key (tenant_id, member_id) references members (tenant_id, id)
) partition by range (day);
create index observation_texts_member_ts on observation_texts (tenant_id, member_id, ts);
create table observation_texts_default partition of observation_texts default;

-- Creates one partition per UTC day for both capture tables, from from_day for `days` days, and puts each new
-- partition behind both walls at creation (a child partition does not inherit FORCE). Rows for that day already in
-- the DEFAULT partition move into the new partition. Idempotent. Returns the names of the partitions it created.
create function ensure_partitions(from_day date, days integer) returns setof text
language plpgsql security definer set search_path = pg_catalog, public, pg_temp as $$
declare
  parent text;
  d date;
  part text;
begin
  if days is null or days < 1 or days > 366 then
    raise exception 'ensure_partitions: days must be 1..366' using errcode = '22023';
  end if;
  perform pg_advisory_xact_lock(hashtextextended('ensure_partitions', 0));
  foreach parent in array array['observations', 'observation_texts'] loop
    for i in 0 .. days - 1 loop
      d := from_day + i;
      part := format('%s_p%s', parent, to_char(d, 'YYYYMMDD'));
      continue when to_regclass(format('public.%I', part)) is not null;
      execute format('create table public.%I (like public.%I including defaults including constraints)', part, parent);
      execute format(
        'with moved as (delete from public.%I where day >= %L and day < %L returning *) insert into public.%I select * from moved',
        parent || '_default', d, d + 1, part);
      execute format('alter table public.%I attach partition public.%I for values from (%L) to (%L)', parent, part, d, d + 1);
      perform apply_tenant_rls(format('public.%I', part)::regclass);
      perform apply_member_isolation(format('public.%I', part)::regclass);
      return next part;
    end loop;
  end loop;
end $$;
revoke all on function ensure_partitions(date, integer) from public;
