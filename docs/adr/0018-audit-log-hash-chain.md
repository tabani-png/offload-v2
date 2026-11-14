# 0018. Audit log: append-only, hash-chained, anchored

Status: accepted · Date: 2026-11-14 · Carries over old ADR 0108 and old `control/src/audit/*`

## Context
Every approval, commit, policy decision, person-data read and settings change must be provable after the fact.

## Decision
- Table `audit_events`, one chain per tenant. `hash = sha256(prev_hash || JCS(event_without_hash))`. First event of a
  tenant uses `prev_hash = 64 zeros`.
- Written **in the same transaction** as the change it records (rollback leaves no event), under
  `pg_advisory_xact_lock(hashtextextended('audit:' || tenant_id, 0))`. `UNIQUE (tenant_id, prev_hash)` prevents forks.
- `offload_app` has INSERT and SELECT only. A trigger refuses UPDATE, DELETE and TRUNCATE for every role but
  `offload_retention`, which may delete only events past retention and only from the oldest end, after writing an
  anchor.
- **Anchors**: a job copies each tenant's chain head into `audit_anchors` hourly and signs a checkpoint with the
  service's Ed25519 key. `GET /v1/audit-events/verify` recomputes the chain and checks anchors.
- Event `action` matches `^[a-z_]+\.[a-z_]+$` (for example `build.approved`, `batch.committed`, `policy.decided`,
  `person.read`, `privacy.leak_blocked`). Events carry ids and hashes, never message bodies or recipients
  (`item_ref = sha256(routine_id NUL item_key)[0:16]`).
- **Core**: the chain, verify endpoint, in-app viewer, retention default 6 years for team tenants and 1 year for
  personal tenants.
- **EE**: export (JSONL, CSV), streaming to a SIEM (webhook, S3), configurable retention, legal hold.

## Consequences
- Audit writes add a lock per tenant per transaction; fine at expected volume.

## Alternatives considered
- External append-only store (QLDB-like): extra system. The hash chain plus anchors gives tamper evidence in Postgres.

## Sources
Old ADR 0108 section 5; old `control/src/audit/{audit,anchor,verify-chain}.ts`, migration `0103_wave_a`.
