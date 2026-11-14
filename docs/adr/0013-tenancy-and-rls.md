# 0013. Tenancy: tenant, workspace, member; Postgres RLS

Status: accepted · Date: 2026-11-14 · Carries over old ADR 0101

## Context
Offload starts as a tenant of one (Muhammad) and grows to Pro teams and Enterprise. Isolation must hold from day one.

## Decision
- Hierarchy: **tenant → workspace → member**. A personal tenant (`kind = 'personal'`) has one workspace and one member
  with role `owner`. Team tenants (`kind = 'team'`) have many.
- One Postgres database, shared schema. Every tenant-owned table has `tenant_id uuid NOT NULL`, first in its primary key
  or a unique index, FK to `tenants`.
- `ENABLE` and `FORCE ROW LEVEL SECURITY` on every tenant-owned table, with policy
  `tenant_isolation USING (tenant_id = nullif(current_setting('app.tenant_id', true), '')::uuid) WITH CHECK (same)`.
  An unset tenant sees zero rows.
- Database roles: `offload_migrator` owns tables; `offload_app` is not owner, has no `BYPASSRLS`, and has no DELETE on
  `audit_events`, `item_journal`, `budget_entries` or `approvals`; `offload_retention` deletes expired rows only, used by
  the retention job.
- `withTenant(ctx, fn)` opens one transaction and runs `SET LOCAL app.tenant_id`, `app.principal_id`, `app.tenant_role`.
  The tenant id comes only from a verified session or device token, never from a request body.
- Workspace scoping is enforced in the authorization layer (Cedar, [ADR 0017](0017-policy-engine-cedar.md)), not in RLS.
  RLS is the tenant wall; Cedar decides within it.
- Per-person data in team tenants (per-person views, working time) gets a second restrictive policy
  `person_visibility`, set only after authorization and an audit write in the same transaction (old ADR 0101/0108).
- A test fails if any table lacks RLS, except the global allowlist `tenants`, `schema_migrations`, `license_state`.
- Regional hosting: a tenant has `region` (default from [OQ-01](../OPEN_QUESTIONS.md#oq-01-cloud-hosting-provider-and-region)).
  One database per region; tenants do not move between regions without an export/import.

## Consequences
- Tests run against PGlite (Postgres in WASM) or a real Postgres 17; RLS tests must use a non-owner role.
- Enterprise "dedicated" deployments are the same code with one tenant per database.

## Alternatives considered
- Schema per tenant or database per tenant for everyone: heavier migrations, no benefit for personal tenants.

## Sources
Old ADR 0101, 0102, 0108; old `control/migrations/0102_rls_roles.sql`.
