---
id: m1-02-tenancy-rls
title: Postgres 17 migrations for tenancy and capture tables with forced RLS, roles, withTenant, and the durable-runtime spike
milestone: M1
status: ready
depends_on: [m1-01-contracts-ingest]
parallel_safe: true
human_gated: false
verify: bash slices/m1-02-tenancy-rls/verify.sh
min_tests: 14
paths_in_scope: [packages/db/**, packages/testkit/**, slices/m1-02-tenancy-rls/**, infra/docker-compose/**, docs/DATA_MODEL.md, package.json, bun.lock]
paths_out_of_scope: [ee/**, apps/**, services/brain/**, services/builder/**, services/runtime/**, docs/adr/**]
red_tests: [MIGRATE, RLS, ROLE, DURABLE]
---

# m1-02-tenancy-rls

## Summary
Creates the first schema: `tenants`, `workspaces`, `members`, `workspace_members`, `sessions`, `devices`,
`device_nonces`, `ingest_batches`, `observations` (partitioned by day), `exclusions`, `audit_events` (table only; chain
writer comes in M5), `purge_log`, `events_outbox`, `license_state`. Implements [ADR 0013](../../docs/adr/0013-tenancy-and-rls.md)
and runs the Bun compatibility spike from [ADR 0009](../../docs/adr/0009-durable-execution-on-postgres.md).

## Contract
- Plain SQL migrations in `packages/db/migrations/NNNN_name.sql`, applied in order, checksummed in `schema_migrations`.
- Roles `offload_migrator` (owner), `offload_app` (no BYPASSRLS, no DELETE on `audit_events`, `purge_log`),
  `offload_retention` (DELETE on `observations` partitions and expired rows only).
- Every tenant table: `ENABLE` + `FORCE ROW LEVEL SECURITY`, policy `tenant_isolation` exactly as in ADR 0013.
- `withTenant({ tenantId, principalId, tenantRole }, fn)` runs `fn` in one transaction after `SET LOCAL app.tenant_id`,
  `app.principal_id`, `app.tenant_role`.
- `createPersonalTenant(idpSubject, email)` creates tenant (`kind = 'personal'`), one workspace, one `owner` member.
- `DurableRuntime` port with a DBOS Transact adapter; if the DURABLE tests fail on Bun, implement the graphile-worker +
  `durable.steps` fallback behind the same port and record it under "Scope changes".
- Tests run against PGlite with pgvector, or a real Postgres 17 from `infra/docker-compose` when `DATABASE_URL` is set.

## Red tests
Folder: `packages/db/tests/m1-02-tenancy-rls/`.

| Tag | Test name | Asserts |
|---|---|---|
| MIGRATE | MIGRATE: migrations apply in order on an empty database | |
| MIGRATE | MIGRATE: a changed applied migration fails its checksum | |
| MIGRATE | MIGRATE: observations is partitioned by day | |
| RLS | RLS: every tenant table has FORCE ROW LEVEL SECURITY | query `pg_class` for all tables except the allowlist |
| RLS | RLS: offload_app with tenant A reads zero rows of tenant B | for every tenant table |
| RLS | RLS: with app.tenant_id unset offload_app reads zero rows | |
| RLS | RLS: inserting a row for another tenant fails WITH CHECK | |
| ROLE | ROLE: offload_app cannot DELETE from audit_events | |
| ROLE | ROLE: offload_app has no BYPASSRLS | |
| ROLE | ROLE: createPersonalTenant makes one tenant, one workspace, one owner | |
| ROLE | ROLE: removing the last owner fails | 409 `last_owner` at the db helper level |
| DURABLE | DURABLE: a two-step workflow killed between steps resumes once on Bun | step 1 runs once, step 2 runs once |
| DURABLE | DURABLE: workflow input carries tenant_id and steps run inside withTenant | |
| DURABLE | DURABLE: a scheduled workflow fires on its cron in a fake clock | |

## Out of scope
HTTP routes, device auth, audit chain hashing, user-model tables.

## Verify
`bash slices/m1-02-tenancy-rls/verify.sh`.

## Scope changes
None.
