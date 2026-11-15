-- m1-03-tenancy-rls. Audit chain (ADR 0018), purge records and the events outbox, DATA_MODEL.md section 8.

-- One chain per tenant: hash = sha256Hex(prev_hash || JCS(event_without_hash)); the first prev_hash is 64 zeros.
-- Written only by appendAudit (packages/db/src/audit.ts). details holds ids and hashes only.
create table audit_events (
  tenant_id uuid not null references tenants(id),
  seq bigint not null check (seq >= 1),
  id text not null check (id ~ '^[0-7][0-9A-HJKMNP-TV-Z]{25}$'),
  at timestamptz not null,
  principal_id text not null check (principal_id ~ '^[A-Za-z0-9_:.-]{1,128}$'),
  action text not null check (action ~ '^[a-z_]+\.[a-z_]+$'),
  subject_type text check (subject_type ~ '^[a-z_]{1,64}$'),
  subject_id text check (subject_id ~ '^[A-Za-z0-9_:.-]{1,128}$'),
  rule_id text check (rule_id ~ '^[A-Za-z0-9_:.-]{1,128}$'),
  details jsonb not null default '{}'::jsonb check (jsonb_typeof(details) = 'object'),
  prev_hash text not null check (prev_hash ~ '^[0-9a-f]{64}$'),
  hash text not null check (hash ~ '^[0-9a-f]{64}$'),
  primary key (tenant_id, seq),
  unique (tenant_id, prev_hash),
  unique (tenant_id, id)
);

create table audit_anchors (
  tenant_id uuid not null references tenants(id),
  seq bigint not null,
  head_hash text not null check (head_hash ~ '^[0-9a-f]{64}$'),
  signed_at timestamptz not null default now(),
  signature text not null,
  key_id text not null,
  sink_ref text,
  primary key (tenant_id, seq)
);

create table purge_requests (
  tenant_id uuid not null references tenants(id),
  id uuid not null,
  member_id uuid not null,
  scope text not null check (scope in ('entity', 'range', 'all', 'import')),
  scope_ref text,
  state text not null default 'queued' check (state in ('queued', 'running', 'done', 'failed')),
  requested_by uuid not null,
  created_at timestamptz not null default now(),
  finished_at timestamptz,
  primary key (tenant_id, id),
  foreign key (tenant_id, member_id) references members (tenant_id, id)
);

create table purge_log (
  tenant_id uuid not null references tenants(id),
  id uuid not null,
  purge_request_id uuid,
  scope text not null check (scope in ('entity', 'range', 'all', 'import', 'raw_ttl', 'text_ttl', 'content_ttl')),
  scope_ref text,
  rows_deleted jsonb not null default '{}'::jsonb,
  requested_by text,
  at timestamptz not null default now(),
  primary key (tenant_id, id)
);

create table events_outbox (
  tenant_id uuid not null references tenants(id),
  id uuid not null,
  type text not null,
  version integer not null default 1,
  payload jsonb not null default '{}'::jsonb, -- ids only
  created_at timestamptz not null default now(),
  primary key (tenant_id, id)
);

create table outbox_deliveries (
  tenant_id uuid not null references tenants(id),
  event_id uuid not null,
  consumer text not null check (consumer ~ '^(workflow|webhook):[A-Za-z0-9_.-]{1,96}$'),
  attempts integer not null default 0,
  delivered_at timestamptz,
  last_error_code text,
  primary key (tenant_id, event_id, consumer),
  foreign key (tenant_id, event_id) references events_outbox (tenant_id, id)
);

select apply_append_only('public.audit_events'::regclass);
select apply_append_only('public.audit_anchors'::regclass);
select apply_append_only('public.purge_log'::regclass);
