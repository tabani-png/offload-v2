-- 0002_fixes: the proposed fix options of finder opportunities (docs/DATA_MODEL.md section 6, slice m5-04) and the
-- hosts of each episode (section 4), so a week's task evidence knows which web apps a workflow touches.
-- Hosts are bare hosts (C1 metadata, like task_ledger.host). Same rules as 0001: tenant_id + member_id, ENABLE + FORCE
-- ROW LEVEL SECURITY, tenant_isolation and the restrictive member_isolation. offload_app may DELETE fixes: options of
-- an open opportunity are replaced when it is ranked again, and go with an open opportunity that leaves the top 5.

ALTER TABLE episodes ADD COLUMN hosts text[] NOT NULL DEFAULT '{}';

CREATE TABLE fixes (
  tenant_id uuid NOT NULL,
  id uuid NOT NULL,
  member_id uuid NOT NULL,
  workspace_id uuid NOT NULL,
  opportunity_id uuid NOT NULL,
  option_no smallint NOT NULL CHECK (option_no BETWEEN 1 AND 3),
  kind text NOT NULL CHECK (kind IN ('agent_workflow','api_integration','scheduled_routine','script','browser_automation','small_app','setup_change','remove_step')),
  rule text NOT NULL,
  recommended boolean NOT NULL DEFAULT false,
  title text NOT NULL CHECK (char_length(title) BETWEEN 1 AND 200),
  detail text NOT NULL DEFAULT '' CHECK (char_length(detail) <= 1000),
  estimate jsonb NOT NULL,
  confidence numeric NOT NULL CHECK (confidence BETWEEN 0 AND 1),
  effort_hours numeric NOT NULL CHECK (effort_hours >= 0),
  figures jsonb NOT NULL,
  steps jsonb NOT NULL,
  chosen_at timestamptz,
  created_at timestamptz NOT NULL,
  PRIMARY KEY (tenant_id, id),
  UNIQUE (tenant_id, opportunity_id, option_no),
  FOREIGN KEY (tenant_id, opportunity_id) REFERENCES opportunities (tenant_id, id) ON DELETE CASCADE
);
-- At most one recommended option per opportunity.
CREATE UNIQUE INDEX fixes_recommended ON fixes (tenant_id, opportunity_id) WHERE recommended;

ALTER TABLE fixes ENABLE ROW LEVEL SECURITY;
ALTER TABLE fixes FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON fixes
  USING (tenant_id = nullif(current_setting('app.tenant_id', true), '')::uuid)
  WITH CHECK (tenant_id = nullif(current_setting('app.tenant_id', true), '')::uuid);
CREATE POLICY member_isolation ON fixes AS RESTRICTIVE
  USING (member_id = nullif(current_setting('app.member_id', true), '')::uuid
         OR current_setting('app.member_scope', true) = 'tenant');
GRANT SELECT, INSERT, UPDATE, DELETE ON fixes TO offload_app;
