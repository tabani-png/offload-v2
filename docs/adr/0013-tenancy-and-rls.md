# 0013. Tenancy: tenant, workspace, member; Postgres RLS

Status: accepted, revised 2026-11-14 · Date: 2026-11-14 · Carries over old ADR 0101

## Context
Offload starts as a tenant of one (Muhammad) and grows to Pro teams and Enterprise. Isolation must hold from day one,
including between members of one team tenant: their screen-derived data must not leak to each other through a query
bug ([design review C (2026-11-14)](../SOURCES.md#design-review-c), P1(5)).

## Decision
- Hierarchy: **tenant → workspace → member**. A personal tenant (`kind = 'personal'`) has one workspace and one member
  with role `owner`. Team tenants (`kind = 'team'`) have many; creating them is gated by plan (decided in [OQ-13](../OPEN_QUESTIONS.md#oq-13-plan-contents-and-prices)).
- One Postgres database, shared schema. Every tenant-owned table has `tenant_id uuid NOT NULL`, first in its primary key
  or a unique index, FK to `tenants`.
- **Tenant wall**: `ENABLE` and `FORCE ROW LEVEL SECURITY` on every tenant-owned table, with policy
  `tenant_isolation USING (tenant_id = nullif(current_setting('app.tenant_id', true), '')::uuid) WITH CHECK (same)`.
  An unset tenant sees zero rows. `tenants` itself has RLS on `id = app.tenant_id`; `createPersonalTenant` sets
  `app.tenant_id` to the new id before inserting.
- **Member wall**: every C1, C2 and C6 table (the tables marked **MI** in
  [DATA_MODEL.md](../DATA_MODEL.md#1-conventions), which is the list of record; today: observations, observation
  texts, keyframes, imports, episodes, task instances, task ledger, entities, entity aliases, facts, propositions,
  records, figure index, profiles, goals, exclusions, review answers, opportunities, fixture sets, fixture token maps,
  instant reads) also has a restrictive policy
  `member_isolation AS RESTRICTIVE USING (member_id = nullif(current_setting('app.member_id', true), '')::uuid OR current_setting('app.member_scope', true) = 'tenant')`.
  `app.member_scope = 'tenant'` is set only by audited aggregate jobs (team floor-of-5 aggregates). For a tenant of one
  it costs nothing.
- **Partitions**: RLS is enabled and forced on every partition when it is created, by the same function that creates it.
- Database roles:
  - `offload_migrator` owns tables and functions.
  - `offload_app`: not owner, no `BYPASSRLS`; no DELETE on the append-only tables listed in
    [DATA_MODEL.md section 1](../DATA_MODEL.md#1-conventions).
  - `offload_retention`: deletes expired rows and drops expired partitions only; used by the retention job.
  - `offload_jobs`: cross-tenant jobs (nightly records, retention, anchors, outbox). It may only execute
    `jobs_list_tenants()` and `outbox_claim(limit)`, which return ids; it then works per tenant through `withTenant`.
- **Bootstrap resolvers**: lookups that happen before the tenant is known run through `SECURITY DEFINER` functions owned
  by `offload_migrator`, returning ids only and nothing for unknown keys:
  `auth_resolve_identity(idp_subject) → (tenant_id, member_id)`,
  `auth_resolve_session(token_sha256) → (tenant_id, member_id, tenant_role, expires_at, last_seen_at)`,
  `auth_resolve_device(device_id) → (tenant_id, member_id, revoked_at)`,
  `auth_resolve_enrollment_code(code_sha256) → (tenant_id, member_id, code_challenge, redirect_uri, expires_at, used_at)`,
  `auth_resolve_pat(token_sha256) → (tenant_id, member_id, scopes, revoked_at)`. `offload_app` has EXECUTE on them.
- `withTenant(ctx, fn)` opens one transaction and runs `SET LOCAL app.tenant_id`, `app.member_id`, `app.principal_id`,
  `app.tenant_role`, and `app.member_scope` (default `member`). The tenant id comes only from a verified session or
  device token, never from a request body.
- **No network I/O inside `withTenant`.** Model calls, connector calls, sandbox calls and webhook sends happen outside
  the transaction; results are written in a second short transaction. The per-tenant audit advisory lock
  ([ADR 0018](0018-audit-log-hash-chain.md)) is taken last, right before commit.
- Workspace scoping and roles are enforced in the authorization layer (the policy engine, [ADR 0017](0017-policy-engine-cedar.md)).
- Per-person views in team tenants (old ADR 0101/0108) additionally need an enablement record and an audit write in the
  same transaction ([OQ-15](../OPEN_QUESTIONS.md#oq-15-monitoring-law-features-for-teams)).
- A test fails if any table in schema `public` (`relkind IN ('r','p')`) lacks forced RLS, except the global allowlist
  `schema_migrations` and `license_state`. Schema `durable` is allowlisted explicitly because it holds ids only
  ([ADR 0009](0009-durable-execution-on-postgres.md)).
- Regional hosting: a tenant has `region` (default from [OQ-01](../OPEN_QUESTIONS.md#oq-01-cloud-hosting-provider-and-region)).
  One database per region; tenants do not move between regions without an export/import.

## Consequences
- Tests for roles, RLS, partitions and durable workflows run on a real Postgres 17 (CI service container); PGlite is
  for fast unit tests that touch none of those.
- Enterprise "dedicated" deployments are the same code with one tenant per database.
- Code that needs a network call mid-flow is split into two transactions; reviewers check for it.

## Alternatives considered
- Schema per tenant or database per tenant for everyone: heavier migrations, no benefit for personal tenants.
- Tenant-only RLS with member checks in authorization code (the previous version). Rejected: one query bug shows a
  colleague's screen-derived data ([design review C (2026-11-14)](../SOURCES.md#design-review-c), P1(5)).

## Sources
Old ADR 0101, 0102, 0108; old `control/migrations/0102_rls_roles.sql`.

## Revisions
- 2026-11-14: member-level restrictive RLS on C1/C2/C6 tables, no network I/O inside `withTenant`, audit lock last
  ([design review C (2026-11-14)](../SOURCES.md#design-review-c), P1(5)); bootstrap resolver functions ([design review A (2026-11-14)](../SOURCES.md#design-review-a), #2); `tenants` under RLS ([design review A (2026-11-14)](../SOURCES.md#design-review-a), #28); partitions and
  `durable` schema rules ([design review A (2026-11-14)](../SOURCES.md#design-review-a), #27); append-only list links DATA_MODEL ([design review A (2026-11-14)](../SOURCES.md#design-review-a), #30); `offload_jobs` role
  ([design review C (2026-11-14)](../SOURCES.md#design-review-c), P2); real Postgres in CI ([design review C (2026-11-14)](../SOURCES.md#design-review-c), P2, [design review A (2026-11-14)](../SOURCES.md#design-review-a), #10).
- 2026-11-14 (final pass): member-wall list points at DATA_MODEL's MI marks and adds the missing MI tables (final-pass audit).
