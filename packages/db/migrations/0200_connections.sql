-- m2-02-connections-catalog. Connection records and connection pins, DATA_MODEL.md section 8 (ADR 0033, ADR 0010).
-- No secret lives here: tokens and API keys stay in the broker (ADR 0034). `external_ref` is the broker-side id
-- (Composio connected account id, MCP grant id) and `account_hash` the sha256 hex of the provider account id; neither
-- is ever sent on the wire. Tenant wall (ENABLE + FORCE + tenant_isolation); not member-isolated (no C1, C2, C6 data).
-- offload_app has no DELETE: a removed connection becomes `revoked`.

create table connections (
  tenant_id uuid not null references tenants(id),
  id uuid not null,
  workspace_id uuid not null,
  member_id uuid null,
  adapter text not null check (adapter in ('mcp', 'composio', 'openapi', 'browser')),
  provider text not null check (provider ~ '^[a-z][a-z0-9_]{0,63}$'),
  account_label text null check (char_length(account_label) <= 256),
  capabilities text[] not null default '{}',
  external_ref text null check (char_length(external_ref) <= 512),
  account_hash text null check (account_hash ~ '^[0-9a-f]{64}$'),
  state text not null default 'needs_reauth' check (state in ('active', 'needs_reauth', 'revoked')),
  created_at timestamptz not null default now(),
  primary key (tenant_id, id),
  foreign key (tenant_id, workspace_id) references workspaces (tenant_id, id),
  foreign key (tenant_id, member_id) references members (tenant_id, id)
);

create table connection_tool_pins (
  tenant_id uuid not null references tenants(id),
  connection_id uuid not null,
  tool_name text not null check (tool_name ~ '^[A-Za-z0-9_.:-]{1,128}$'),
  pin_hash text not null check (pin_hash ~ '^[0-9a-f]{64}$'),
  pinned_at timestamptz not null default now(),
  primary key (tenant_id, connection_id, tool_name),
  foreign key (tenant_id, connection_id) references connections (tenant_id, id)
);

select apply_tenant_rls('public.connections'::regclass);
select apply_tenant_rls('public.connection_tool_pins'::regclass);

grant select, insert, update on connections, connection_tool_pins to offload_app;
