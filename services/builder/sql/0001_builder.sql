-- services/builder schema (DATA_MODEL section 6 and section 8). Applied by services/builder/src/store-pg.ts until
-- packages/db adopts it (with FKs to tenants and the shared append-only trigger function). Unqualified names: the
-- caller's search_path picks the schema. Money is numeric(10,4) USD; hashes are lowercase hex text.

CREATE TABLE builds (
  tenant_id uuid NOT NULL,
  id uuid NOT NULL,
  fix_id text NOT NULL,
  brief_id text NOT NULL,
  approval_id uuid,
  state text NOT NULL CHECK (state IN ('queued','building','verifying','fanning_out','repairing','ready','failed','capped','tampered','cancelled','infra_failed')),
  cap_usd numeric(10,4) NOT NULL CHECK (cap_usd > 0),
  spent_usd numeric(10,4) NOT NULL DEFAULT 0 CHECK (spent_usd >= 0),
  fanout_workers int NOT NULL CHECK (fanout_workers BETWEEN 1 AND 3),
  infra_retries int NOT NULL DEFAULT 0,
  bound_hashes jsonb NOT NULL,
  stages jsonb NOT NULL DEFAULT '[]'::jsonb,
  winner_attempt_id uuid,
  artifact_sha256 text CHECK (artifact_sha256 ~ '^[0-9a-f]{64}$'),
  receipt_hash text CHECK (receipt_hash ~ '^[0-9a-f]{64}$'),
  definition_hash text CHECK (definition_hash ~ '^[0-9a-f]{64}$'),
  created_at timestamptz NOT NULL,
  heartbeat_at timestamptz NOT NULL,
  started_at timestamptz,
  ended_at timestamptz,
  deployed_at timestamptz,
  PRIMARY KEY (tenant_id, id)
);
-- The build lock: one live build per brief (API.md 409 already_running).
CREATE UNIQUE INDEX builds_one_live_per_brief ON builds (tenant_id, brief_id)
  WHERE state IN ('queued','building','verifying','fanning_out','repairing');
CREATE INDEX builds_held_out ON builds (tenant_id, brief_id, (bound_hashes->>'held_out_hash'));

CREATE TABLE worker_attempts (
  tenant_id uuid NOT NULL,
  id uuid NOT NULL,
  build_id uuid NOT NULL,
  ordinal int NOT NULL CHECK (ordinal >= 1),
  sandbox_provider text NOT NULL,
  sandbox_id text,
  outcome text NOT NULL CHECK (outcome IN ('running','pass','fail','cap','tamper','error')),
  spent_usd numeric(10,4) NOT NULL DEFAULT 0,
  tries int NOT NULL DEFAULT 0,
  turns int NOT NULL DEFAULT 0,
  frozen_pass boolean,
  held_out_pass boolean,
  check_groups jsonb NOT NULL DEFAULT '[]'::jsonb,
  artifact_sha256 text CHECK (artifact_sha256 ~ '^[0-9a-f]{64}$'),
  artifact_bytes bigint NOT NULL DEFAULT 0,
  artifact_files jsonb NOT NULL DEFAULT '[]'::jsonb,
  note text NOT NULL DEFAULT '',
  PRIMARY KEY (tenant_id, id),
  FOREIGN KEY (tenant_id, build_id) REFERENCES builds (tenant_id, id)
);

CREATE TABLE budget_reservations (
  tenant_id uuid NOT NULL,
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  build_id uuid NOT NULL,
  attempt_id text NOT NULL,
  call_id text NOT NULL,
  kind text NOT NULL CHECK (kind IN ('model','sandbox')),
  reserved_usd numeric(10,4) NOT NULL CHECK (reserved_usd > 0),
  created_at timestamptz NOT NULL,
  settled_at timestamptz,
  PRIMARY KEY (tenant_id, id),
  FOREIGN KEY (tenant_id, build_id) REFERENCES builds (tenant_id, id)
);
CREATE INDEX budget_reservations_open ON budget_reservations (tenant_id, build_id) WHERE settled_at IS NULL;

CREATE TABLE budget_entries (
  tenant_id uuid NOT NULL,
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  idempotency_key text NOT NULL,
  scope text NOT NULL CHECK (scope IN ('build','design','run','brain','infra')),
  scope_id uuid NOT NULL,
  model text,
  input_tokens int,
  output_tokens int,
  cache_read_tokens int,
  sandbox_seconds int,
  usd numeric(10,4) NOT NULL CHECK (usd >= 0),
  at timestamptz NOT NULL,
  PRIMARY KEY (tenant_id, id),
  UNIQUE (tenant_id, idempotency_key)
);

CREATE TABLE build_receipts (
  tenant_id uuid NOT NULL,
  build_id uuid NOT NULL,
  receipt jsonb NOT NULL,
  receipt_hash text NOT NULL CHECK (receipt_hash ~ '^[0-9a-f]{64}$'),
  signature text,
  key_id text,
  PRIMARY KEY (tenant_id, build_id),
  FOREIGN KEY (tenant_id, build_id) REFERENCES builds (tenant_id, id)
);

-- budget_entries is append-only (DATA_MODEL section 1). packages/db's shared trigger lets offload_retention delete
-- past retention; this local one refuses every change.
CREATE FUNCTION builder_append_only() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION '% is append-only', TG_TABLE_NAME;
END $$;
CREATE TRIGGER budget_entries_append_only BEFORE UPDATE OR DELETE ON budget_entries
  FOR EACH ROW EXECUTE FUNCTION builder_append_only();
CREATE TRIGGER budget_entries_no_truncate BEFORE TRUNCATE ON budget_entries
  FOR EACH STATEMENT EXECUTE FUNCTION builder_append_only();

-- Tenant RLS (ADR 0013): ENABLE + FORCE, one policy per table.
ALTER TABLE builds ENABLE ROW LEVEL SECURITY;
ALTER TABLE builds FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON builds USING (tenant_id = nullif(current_setting('app.tenant_id', true), '')::uuid) WITH CHECK (tenant_id = nullif(current_setting('app.tenant_id', true), '')::uuid);
ALTER TABLE worker_attempts ENABLE ROW LEVEL SECURITY;
ALTER TABLE worker_attempts FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON worker_attempts USING (tenant_id = nullif(current_setting('app.tenant_id', true), '')::uuid) WITH CHECK (tenant_id = nullif(current_setting('app.tenant_id', true), '')::uuid);
ALTER TABLE budget_reservations ENABLE ROW LEVEL SECURITY;
ALTER TABLE budget_reservations FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON budget_reservations USING (tenant_id = nullif(current_setting('app.tenant_id', true), '')::uuid) WITH CHECK (tenant_id = nullif(current_setting('app.tenant_id', true), '')::uuid);
ALTER TABLE budget_entries ENABLE ROW LEVEL SECURITY;
ALTER TABLE budget_entries FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON budget_entries USING (tenant_id = nullif(current_setting('app.tenant_id', true), '')::uuid) WITH CHECK (tenant_id = nullif(current_setting('app.tenant_id', true), '')::uuid);
ALTER TABLE build_receipts ENABLE ROW LEVEL SECURITY;
ALTER TABLE build_receipts FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON build_receipts USING (tenant_id = nullif(current_setting('app.tenant_id', true), '')::uuid) WITH CHECK (tenant_id = nullif(current_setting('app.tenant_id', true), '')::uuid);
