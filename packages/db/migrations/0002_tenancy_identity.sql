-- m1-03-tenancy-rls. Tenancy and identity tables, DATA_MODEL.md section 3. Hashes are lowercase hex sha256.

create table tenants (
  id uuid primary key,
  kind text not null check (kind in ('personal', 'team')),
  name text not null,
  region text not null default 'ca-central-1', -- OQ-01 default
  plan text not null default 'free' check (plan in ('free', 'pro', 'enterprise')),
  reporting_timezone text not null default 'UTC',
  monthly_model_budget_usd numeric(10,4) not null default 50.0000, -- OQ-05 default
  created_at timestamptz not null default now(),
  deleted_at timestamptz
);

create table workspaces (
  tenant_id uuid not null references tenants(id),
  id uuid not null,
  name text not null,
  created_at timestamptz not null default now(),
  archived_at timestamptz,
  primary key (tenant_id, id)
);

create table members (
  tenant_id uuid not null references tenants(id),
  id uuid not null,
  email text not null,
  email_hash text not null check (email_hash ~ '^[0-9a-f]{64}$'),
  display_name text,
  tenant_role text not null check (tenant_role in ('owner', 'admin', 'member', 'auditor')),
  state text not null check (state in ('invited', 'active', 'leaving', 'frozen', 'departed')),
  idp_subject text,
  created_at timestamptz not null default now(),
  primary key (tenant_id, id)
);
create unique index members_idp_subject on members (idp_subject) where idp_subject is not null;
create index members_owners on members (tenant_id) where tenant_role = 'owner';

create table workspace_members (
  tenant_id uuid not null references tenants(id),
  workspace_id uuid not null,
  member_id uuid not null,
  workspace_role text not null check (workspace_role in ('lead', 'member')),
  primary key (tenant_id, workspace_id, member_id),
  foreign key (tenant_id, workspace_id) references workspaces (tenant_id, id),
  foreign key (tenant_id, member_id) references members (tenant_id, id)
);

create table sessions (
  tenant_id uuid not null references tenants(id),
  id uuid not null,
  member_id uuid not null,
  token_sha256 text not null check (token_sha256 ~ '^[0-9a-f]{64}$'),
  csrf_sha256 text not null check (csrf_sha256 ~ '^[0-9a-f]{64}$'),
  created_at timestamptz not null default now(),
  last_seen_at timestamptz not null default now(),
  expires_at timestamptz not null,
  revoked_at timestamptz,
  primary key (tenant_id, id),
  foreign key (tenant_id, member_id) references members (tenant_id, id)
);
create unique index sessions_token on sessions (token_sha256);

create table devices (
  tenant_id uuid not null references tenants(id),
  id uuid not null,
  member_id uuid not null,
  public_jwk jsonb not null,
  key_storage text not null check (key_storage in ('secure_enclave', 'keychain')),
  name text not null,
  last_seq bigint not null default 0,
  enrolled_at timestamptz not null default now(),
  revoked_at timestamptz,
  primary key (tenant_id, id),
  foreign key (tenant_id, member_id) references members (tenant_id, id)
);
create unique index devices_id on devices (id);

create table device_nonces (
  tenant_id uuid not null references tenants(id),
  device_id uuid not null,
  nonce text not null,
  audience text not null check (audience in ('device', 'member')),
  expires_at timestamptz not null default now() + interval '2 minutes',
  used_at timestamptz,
  primary key (tenant_id, device_id, nonce),
  foreign key (tenant_id, device_id) references devices (tenant_id, id)
);

create table device_enrollment_codes (
  tenant_id uuid not null references tenants(id),
  code_sha256 text not null check (code_sha256 ~ '^[0-9a-f]{64}$'),
  member_id uuid not null,
  code_challenge text not null,
  redirect_uri text not null,
  expires_at timestamptz not null default now() + interval '10 minutes',
  used_at timestamptz,
  primary key (tenant_id, code_sha256),
  foreign key (tenant_id, member_id) references members (tenant_id, id)
);
create unique index device_enrollment_codes_code on device_enrollment_codes (code_sha256);

create table personal_access_tokens (
  tenant_id uuid not null references tenants(id),
  id uuid not null,
  member_id uuid not null,
  name text not null,
  scopes text[] not null default '{}',
  token_sha256 text not null check (token_sha256 ~ '^[0-9a-f]{64}$'),
  created_at timestamptz not null default now(),
  last_used_at timestamptz,
  revoked_at timestamptz,
  primary key (tenant_id, id),
  foreign key (tenant_id, member_id) references members (tenant_id, id)
);
create unique index personal_access_tokens_token on personal_access_tokens (token_sha256);

create table pseudonym_key_wraps (
  tenant_id uuid not null references tenants(id),
  device_id uuid not null,
  wrapped_key text not null,
  wrapped_by_device_id uuid,
  method text not null check (method in ('device', 'recovery_code')),
  recovery_wrap text,
  created_at timestamptz not null default now(),
  primary key (tenant_id, device_id),
  foreign key (tenant_id, device_id) references devices (tenant_id, id)
);

create table idempotency_keys (
  tenant_id uuid not null references tenants(id),
  key text not null,
  request_sha256 text not null check (request_sha256 ~ '^[0-9a-f]{64}$'),
  status integer not null,
  response jsonb,
  created_at timestamptz not null default now(),
  primary key (tenant_id, key)
);

-- Global, no RLS (allowlisted): read before any tenant is known; holds a hashed email and a token hash only.
create table magic_links (
  token_sha256 text primary key check (token_sha256 ~ '^[0-9a-f]{64}$'),
  email_hash text not null check (email_hash ~ '^[0-9a-f]{64}$'),
  return_to text not null,
  expires_at timestamptz not null default now() + interval '15 minutes',
  used_at timestamptz
);

-- Global, no RLS (allowlisted). One row per verified license key.
create table license_state (
  key_id text primary key,
  licensee text not null,
  plan text not null check (plan in ('free', 'pro', 'enterprise')),
  features text[] not null default '{}',
  seats integer not null check (seats >= 0),
  issued_at timestamptz not null,
  expires_at timestamptz not null,
  verified_at timestamptz not null default now()
);
