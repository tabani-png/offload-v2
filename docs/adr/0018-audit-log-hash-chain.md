# 0018. Audit log: append-only, hash-chained, anchored

Status: accepted, revised 2026-11-14 · Date: 2026-11-14 · Carries over old ADR 0108 and old `control/src/audit/*`

## Context
Every approval, commit, policy decision, person-data read and settings change must be provable after the fact.

## Decision
- Table `audit_events`, one chain per tenant. `hash = sha256Hex(prev_hash || JCS(event_without_hash))`, where
  `prev_hash` is concatenated as its 64-character lowercase hex ASCII text and `event_without_hash` is the row's event
  object without the `hash` field. First event of a tenant uses `prev_hash` = 64 zeros.
- Written **in the same transaction** as the change it records (rollback leaves no event), under
  `pg_advisory_xact_lock(hashtextextended('audit:' || tenant_id, 0))`, taken last in the transaction
  ([ADR 0013](0013-tenancy-and-rls.md)). `UNIQUE (tenant_id, prev_hash)` prevents forks.
- The chain writer `appendAudit(tx, event)` in `packages/db` is ported from the old `control/src/audit` in M1 (slice
  `m1-03-tenancy-rls`), so every audit row from day one is chained.
- `offload_app` has INSERT and SELECT only. A trigger refuses UPDATE, DELETE and TRUNCATE for every role but
  `offload_retention`, which may delete only events past retention and only from the oldest end, after writing an
  anchor.
- **Anchors**: a job copies each tenant's chain head into `audit_anchors` hourly and signs a checkpoint with the
  service's Ed25519 key (`OFFLOAD_SERVICE_SIGNING_KEY_REF`). `GET /v1/audit-events/verify` recomputes the chain and
  checks anchors.
- **What anchors prove, honestly**: core anchors are signed by a key Offload holds and stored in the same database.
  They detect accidental damage and tampering by someone without that key; they **do not prove anything against the
  operator**. EE adds an **external anchor sink** (`ee/packages/audit-export`): checkpoints written to the customer's
  S3 bucket with object lock, or emailed to an address the customer controls.
- Event `action` matches `^[a-z_]+\.[a-z_]+$` (for example `build.approved`, `batch.committed`, `policy.decided`,
  `person.read`, `privacy.leak_blocked`, `sandbox.reaped`). Events carry ids and hashes, never message bodies or
  recipients (`item_ref = sha256(routine_id NUL item_key)[0:16]`).
- **Core**: the chain, verify endpoint, in-app viewer, retention default 6 years for team tenants and 1 year for
  personal tenants.
- **EE**: export (JSONL, CSV), streaming to a SIEM (webhook, S3), external anchor sink, configurable retention, legal hold.

## Consequences
- Audit writes add a lock per tenant per transaction; fine at expected volume because the lock is taken last and no
  network I/O happens inside the transaction.

## Alternatives considered
- External append-only store (QLDB-like): extra system. The hash chain plus anchors gives tamper evidence in Postgres;
  the external sink covers the operator case for those who need it.

## Sources
Old ADR 0108 section 5; old `control/src/audit/{audit,anchor,verify-chain,anchor-job}.ts`, migration `0103_wave_a`.

## Revisions
- 2026-11-14: one hash formula with the concatenation stated (review-a #86); chain writer ported in M1 (review-a #31);
  anchors described honestly, EE external anchor sink (review-c P1(6)); lock taken last (review-c P1(5)).
