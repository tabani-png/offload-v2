-- 0001_user_model: the R-model tables of the user model (docs/DATA_MODEL.md sections 4 and 6) for services/brain.
-- Owned by services/brain until packages/db's migration runner adopts it; that runner adds the foreign keys to
-- tenants, members and workspaces, which do not exist yet. Names are unqualified: apply with search_path set.
-- Every table: tenant_id + member_id, ENABLE + FORCE ROW LEVEL SECURITY, tenant_isolation and the restrictive
-- member_isolation (docs/adr/0013-tenancy-and-rls.md). offload_app gets SELECT, INSERT, UPDATE; DELETE only on
-- figure_index and opportunities. Rows end with invalid_at / expired_at / archived_at; deletion is the forget path.
-- Vectors are real[] until pgvector is installed (exact scan in code, ADR 0019).

CREATE TABLE profiles (
  tenant_id uuid NOT NULL,
  member_id uuid NOT NULL,
  version integer NOT NULL DEFAULT 0 CHECK (version >= 0),
  role text CHECK (char_length(role) <= 80),
  industry text CHECK (char_length(industry) <= 80),
  drains text[] NOT NULL DEFAULT '{}' CHECK (drains <@ ARRAY['email','meetings','agent_babysitting','reporting','content','admin','context_switching']),
  schedule jsonb,
  timezone text NOT NULL DEFAULT 'UTC',
  review_slot jsonb NOT NULL DEFAULT '{"day":"fri","time":"16:00"}',
  autonomy text NOT NULL DEFAULT 'suggest' CHECK (autonomy IN ('suggest','draft','run_approved')),
  own_name_to_models text NOT NULL DEFAULT 'mask' CHECK (own_name_to_models IN ('mask','keep')),
  keyframes_to_cloud boolean NOT NULL DEFAULT false,
  learning_paused boolean NOT NULL DEFAULT false,
  updated_at timestamptz,
  PRIMARY KEY (tenant_id, member_id)
);

CREATE TABLE goals (
  tenant_id uuid NOT NULL,
  member_id uuid NOT NULL,
  id text NOT NULL CHECK (id ~ '^g_[0-9a-f]{10}$'),
  text text NOT NULL CHECK (char_length(text) BETWEEN 1 AND 80 AND text !~ '[\r\n<>]'),
  horizon text NOT NULL DEFAULT '90d' CHECK (horizon = '90d'),
  position smallint NOT NULL DEFAULT 0,
  embedding real[],
  created_at timestamptz NOT NULL,
  archived_at timestamptz,
  PRIMARY KEY (tenant_id, member_id, id)
);

-- At most 3 active goals per member, whatever writes them.
CREATE FUNCTION goals_max_active() RETURNS trigger LANGUAGE plpgsql SET search_path FROM CURRENT AS $$
BEGIN
  IF (SELECT count(*) FROM goals g WHERE g.tenant_id = NEW.tenant_id AND g.member_id = NEW.member_id AND g.archived_at IS NULL) > 3 THEN
    RAISE EXCEPTION 'at most 3 active goals' USING ERRCODE = 'check_violation';
  END IF;
  RETURN NULL;
END $$;
CREATE CONSTRAINT TRIGGER goals_max_active AFTER INSERT OR UPDATE ON goals
  DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION goals_max_active();

CREATE TABLE task_ledger (
  tenant_id uuid NOT NULL,
  member_id uuid NOT NULL,
  task_key text NOT NULL CHECK (task_key ~ '^k_[0-9a-f]{12}$'),
  signatures text[] NOT NULL,
  task_kind text NOT NULL,
  app_bundle_id text NOT NULL,
  host text NOT NULL,
  name_words text[] NOT NULL,
  name text NOT NULL CHECK (char_length(name) <= 80),
  centroid real[],
  first_seen_day date NOT NULL,
  last_seen_day date NOT NULL,
  PRIMARY KEY (tenant_id, member_id, task_key)
);

CREATE TABLE episodes (
  tenant_id uuid NOT NULL,
  member_id uuid NOT NULL,
  id text NOT NULL CHECK (id ~ '^ep_'),
  kind text NOT NULL CHECK (kind IN ('focus_block','task_instance')),
  day date NOT NULL,
  started_at timestamptz NOT NULL,
  ended_at timestamptz NOT NULL,
  minutes numeric NOT NULL,
  apps text[] NOT NULL,
  task_key text,
  name text NOT NULL CHECK (char_length(name) <= 80),
  evidence text[] NOT NULL,
  source_purged_at timestamptz,
  embedding real[],
  PRIMARY KEY (tenant_id, member_id, id)
);

CREATE TABLE propositions (
  tenant_id uuid NOT NULL,
  member_id uuid NOT NULL,
  id text NOT NULL CHECK (id ~ '^p_[0-9a-f]{10}_v[0-9]+$'),
  key text NOT NULL,
  kind text NOT NULL CHECK (kind IN ('repeats','time_share','sequence')),
  version integer NOT NULL CHECK (version >= 1),
  revision_group text NOT NULL,
  text text NOT NULL,
  confidence smallint NOT NULL CHECK (confidence BETWEEN 1 AND 10),
  confidence_score numeric NOT NULL CHECK (confidence_score BETWEEN 0 AND 1),
  decay smallint NOT NULL CHECK (decay BETWEEN 1 AND 10),
  rate numeric NOT NULL,
  evidence jsonb NOT NULL,
  valid_at timestamptz NOT NULL,
  invalid_at timestamptz,
  recorded_at timestamptz NOT NULL,
  expired_at timestamptz,
  PRIMARY KEY (tenant_id, member_id, id),
  UNIQUE (tenant_id, member_id, key, version),
  CHECK (invalid_at IS NULL OR invalid_at >= valid_at)
);
-- One current version per belief.
CREATE UNIQUE INDEX propositions_current ON propositions (tenant_id, member_id, key) WHERE invalid_at IS NULL;

CREATE TABLE day_records (
  tenant_id uuid NOT NULL,
  member_id uuid NOT NULL,
  day date NOT NULL,
  generated_at timestamptz NOT NULL,
  totals jsonb NOT NULL,
  by_kind jsonb NOT NULL,
  by_app jsonb NOT NULL,
  by_task jsonb NOT NULL,
  episode_ids text[] NOT NULL,
  source_purged_at timestamptz,
  PRIMARY KEY (tenant_id, member_id, day)
);

CREATE TABLE week_records (
  tenant_id uuid NOT NULL,
  member_id uuid NOT NULL,
  iso_week text NOT NULL CHECK (iso_week ~ '^[0-9]{4}-W(0[1-9]|[1-4][0-9]|5[0-3])$'),
  from_day date NOT NULL,
  to_day date NOT NULL,
  days_recorded date[] NOT NULL,
  hours jsonb NOT NULL,
  focus jsonb NOT NULL,
  tasks jsonb NOT NULL,
  fixes jsonb NOT NULL,
  weeks_observed integer NOT NULL CHECK (weeks_observed >= 1),
  narrative text,
  generated_at timestamptz NOT NULL,
  PRIMARY KEY (tenant_id, member_id, iso_week)
);

CREATE TABLE month_records (
  tenant_id uuid NOT NULL,
  member_id uuid NOT NULL,
  month text NOT NULL CHECK (month ~ '^[0-9]{4}-(0[1-9]|1[0-2])$'),
  weeks text[] NOT NULL,
  hours jsonb NOT NULL,
  by_task jsonb NOT NULL,
  persistent text[] NOT NULL,
  trend jsonb NOT NULL,
  drift jsonb NOT NULL,
  realized jsonb,
  outcomes jsonb NOT NULL DEFAULT '[]',
  notes text[] NOT NULL,
  narrative text,
  generated_at timestamptz NOT NULL,
  PRIMARY KEY (tenant_id, member_id, month)
);

CREATE TABLE quarter_records (
  tenant_id uuid NOT NULL,
  member_id uuid NOT NULL,
  quarter text NOT NULL CHECK (quarter ~ '^[0-9]{4}-Q[1-4]$'),
  weeks text[] NOT NULL,
  hours jsonb NOT NULL,
  by_task jsonb NOT NULL,
  persistent text[] NOT NULL,
  trend jsonb NOT NULL,
  drift jsonb NOT NULL,
  realized jsonb,
  outcomes jsonb NOT NULL DEFAULT '[]',
  notes text[] NOT NULL,
  narrative text,
  generated_at timestamptz NOT NULL,
  PRIMARY KEY (tenant_id, member_id, quarter)
);

CREATE TABLE figure_index (
  tenant_id uuid NOT NULL,
  member_id uuid NOT NULL,
  figure_id text NOT NULL CHECK (figure_id ~ '^fig_[0-9a-f]{16}$'),
  record_kind text NOT NULL CHECK (record_kind IN ('day','week','month','quarter','opportunity','run_saving')),
  record_key text NOT NULL,
  json_pointer text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  -- One row per record that holds the figure: identical figures in two records share an id.
  PRIMARY KEY (tenant_id, member_id, figure_id, record_kind, record_key)
);
CREATE INDEX figure_index_record ON figure_index (tenant_id, member_id, record_kind, record_key);

CREATE TABLE review_answers (
  tenant_id uuid NOT NULL,
  member_id uuid NOT NULL,
  iso_week text NOT NULL CHECK (iso_week ~ '^[0-9]{4}-W(0[1-9]|[1-4][0-9]|5[0-3])$'),
  subject_key text NOT NULL,
  question_kind text NOT NULL,
  answer text NOT NULL CHECK (answer IN ('keep','not_now','build','never','leave_alone','yes','no','other_goal','confirm_name','dont_track','undo')),
  goal_id text,
  answered_at timestamptz NOT NULL,
  PRIMARY KEY (tenant_id, member_id, iso_week, subject_key)
);

CREATE TABLE opportunities (
  tenant_id uuid NOT NULL,
  id uuid NOT NULL,
  member_id uuid NOT NULL,
  workspace_id uuid NOT NULL,
  source text NOT NULL CHECK (source IN ('finder','manual','instant_read','agent')),
  task_key text,
  title text NOT NULL,
  description text NOT NULL DEFAULT '',
  iso_week text NOT NULL,
  rank integer,
  score numeric,
  factors jsonb NOT NULL,
  state text NOT NULL DEFAULT 'open' CHECK (state IN ('open','chosen','needs_connection','capturing_fixtures','designing','needs_you','ready_for_approval','building','ready_to_ship','build_failed','shipped','not_now','never','left_alone')),
  not_now_until date,
  goal_id text,
  created_at timestamptz NOT NULL,
  PRIMARY KEY (tenant_id, id)
);
CREATE UNIQUE INDEX opportunities_finder_week ON opportunities (tenant_id, member_id, iso_week, task_key) WHERE source = 'finder';

-- Tenant wall and member wall on every table above.
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['profiles','goals','task_ledger','episodes','propositions','day_records','week_records',
    'month_records','quarter_records','figure_index','review_answers','opportunities'] LOOP
    EXECUTE format('ALTER TABLE %I ENABLE ROW LEVEL SECURITY', t);
    EXECUTE format('ALTER TABLE %I FORCE ROW LEVEL SECURITY', t);
    EXECUTE format($p$CREATE POLICY tenant_isolation ON %I
      USING (tenant_id = nullif(current_setting('app.tenant_id', true), '')::uuid)
      WITH CHECK (tenant_id = nullif(current_setting('app.tenant_id', true), '')::uuid)$p$, t);
    EXECUTE format($p$CREATE POLICY member_isolation ON %I AS RESTRICTIVE
      USING (member_id = nullif(current_setting('app.member_id', true), '')::uuid
             OR current_setting('app.member_scope', true) = 'tenant')$p$, t);
    EXECUTE format('GRANT SELECT, INSERT, UPDATE ON %I TO offload_app', t);
  END LOOP;
END $$;
GRANT DELETE ON figure_index, opportunities TO offload_app;
