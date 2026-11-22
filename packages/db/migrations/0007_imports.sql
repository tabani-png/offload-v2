-- m3-05b-imports-server. Forget scope `import` deletes by import_id (DATA_MODEL.md section 5, `imports`): partial
-- indexes keep that delete off the live store. On a partitioned table each index is created on every partition,
-- including the ones ensure_partitions() makes later.
create index observations_member_import on observations (tenant_id, member_id, import_id) where import_id is not null;
create index observation_texts_member_import on observation_texts (tenant_id, member_id, import_id) where import_id is not null;
-- Forget scope `import` finds the observations.ingested events that name the import (payload import_id, m3-05b).
-- A plain column, not an expression index on payload->>'import_id': under row-level security Postgres does not use
-- a clause that is not leakproof (jsonb ->> is not) as an index condition, so the lookup would filter every event.
-- Only a lower-case uuid becomes a value; anything else stays null (ingest writes lower-case uuids only).
alter table events_outbox add column import_id uuid generated always as (
  case when payload->>'import_id' ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
       then (payload->>'import_id')::uuid end) stored;
create index events_outbox_import on events_outbox (tenant_id, import_id) where import_id is not null;
