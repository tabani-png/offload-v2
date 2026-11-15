-- m2-03-credential-broker. The credential vault and the OAuth request table, DATA_MODEL.md section 8 (ADR 0034).
-- Only the broker (role offload_broker) can read or write these tables: offload_app gets no privilege on them. The
-- plaintext secret is never stored; `ciphertext` is AES-256-GCM under a per-row data key that `wrapped_dek` holds,
-- wrapped by the key provider (`local` or `aws-kms`). R-secret: a row is deleted (crypto-shred) with its connection.

create table credentials (
  tenant_id uuid not null references tenants(id),
  connection_id uuid not null,
  ciphertext bytea not null,
  nonce bytea not null check (octet_length(nonce) = 12),
  wrapped_dek bytea not null,
  key_provider text not null check (key_provider in ('aws-kms', 'gcp-kms', 'local')),
  key_ref text not null check (char_length(key_ref) between 1 and 512),
  scopes text[] not null default '{}',
  expires_at timestamptz null,
  refresh_state text not null default 'ok' check (refresh_state in ('ok', 'refreshing', 'failed', 'revoked')),
  refresh_lease_until timestamptz null,
  last_refreshed_at timestamptz null,
  created_at timestamptz not null default now(),
  rotated_at timestamptz null,
  primary key (tenant_id, connection_id),
  constraint credentials_tenant_connection_key unique (tenant_id, connection_id),
  foreign key (tenant_id, connection_id) references connections (tenant_id, id)
);

-- One row per started OAuth authorization. Only the sha256 of `state` is stored; the PKCE verifier stays here until the
-- code exchange. R-session: single use (`used_at`), valid 10 minutes.
create table oauth_requests (
  tenant_id uuid not null references tenants(id),
  state_sha256 text not null check (state_sha256 ~ '^[0-9a-f]{64}$'),
  connection_id uuid not null,
  member_id uuid not null,
  provider text not null check (provider ~ '^[a-z][a-z0-9_]{0,63}$'),
  code_verifier text not null check (char_length(code_verifier) between 43 and 128),
  redirect_uri text not null check (char_length(redirect_uri) <= 2048),
  created_at timestamptz not null default now(),
  expires_at timestamptz not null,
  used_at timestamptz null,
  primary key (tenant_id, state_sha256),
  foreign key (tenant_id, connection_id) references connections (tenant_id, id),
  foreign key (tenant_id, member_id) references members (tenant_id, id)
);

select apply_tenant_rls('public.credentials'::regclass);
select apply_tenant_rls('public.oauth_requests'::regclass);

-- The broker's role. offload_broker is created by an administrator (migrator has no CREATEROLE; bootstrap and the
-- testkit's ensureBrokerRole do it) and is not an owner and has no BYPASSRLS. When the role is absent the grants are
-- skipped with a notice and re-running the grants after creating the role is the operator's step (docs/DEPLOYMENT.md).
do $$
begin
  if exists (select 1 from pg_roles where rolname = 'offload_broker') then
    grant select, insert, update, delete on credentials, oauth_requests to offload_broker;
    grant select, update (state) on connections to offload_broker;
    grant select, insert on audit_events to offload_broker;
    -- The chain writer takes no other privilege; offload_app and the other roles get nothing on these two tables.
  else
    raise notice 'role offload_broker does not exist: create it, then grant per docs/DEPLOYMENT.md (broker role)';
  end if;
end $$;
