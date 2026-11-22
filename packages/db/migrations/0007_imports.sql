-- m3-05b-imports-server. Forget scope `import` deletes by import_id (DATA_MODEL.md section 5, `imports`): partial
-- indexes keep that delete off the live store. On a partitioned table each index is created on every partition,
-- including the ones ensure_partitions() makes later.
create index observations_member_import on observations (tenant_id, member_id, import_id) where import_id is not null;
create index observation_texts_member_import on observation_texts (tenant_id, member_id, import_id) where import_id is not null;
-- Forget scope `import` finds the observations.ingested events that name the import (payload import_id, m3-05b).
create index events_outbox_import on events_outbox (tenant_id, (payload->>'import_id')) where payload ? 'import_id';
