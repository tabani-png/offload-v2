---
id: m1-03-tenancy-rls
title: Postgres 17 migrations for tenancy, identity and capture tables with forced tenant RLS, restrictive member isolation, roles, resolver functions, withTenant and the audit chain writer
milestone: M1
status: in_progress
depends_on: [m1-01-durable-spike, m1-02-contracts-ingest]
parallel_safe: false
human_gated: false
model_tier: sonnet
size: L
parallel_group: M1-C
owns: [packages/db/**, packages/testkit/**, docs/DATA_MODEL.md]
verify: bash slices/m1-03-tenancy-rls/verify.sh
min_tests: 24
paths_in_scope: [packages/db/**, packages/testkit/**, slices/m1-03-tenancy-rls/**, infra/docker-compose/**, docs/DATA_MODEL.md, package.json, bun.lock]
paths_out_of_scope: [ee/**, apps/**, services/**, packages/contracts/src/**, docs/adr/**]
red_tests: [MIGRATE, RLS, ROLE, AUDIT]
---

# m1-03-tenancy-rls

## Summary
The first schema for [M1](../../docs/ROADMAP.md#m1-foundations). Implements
[ADR 0013](../../docs/adr/0013-tenancy-and-rls.md) (tenant RLS, member isolation, roles, resolver functions, no network
I/O inside `withTenant`), the tables in [DATA_MODEL.md sections 3 and 5](../../docs/DATA_MODEL.md#3-tenancy-and-identity)
and the audit chain writer from [ADR 0018](../../docs/adr/0018-audit-log-hash-chain.md) (ported from old
`control/src/audit`, so it needs the relicensing default of
[OQ-12](../../docs/OPEN_QUESTIONS.md#oq-12-relicensing-code-from-the-old-repo)). Not parallel-safe: it
rebuilds `packages/db` and `packages/testkit`, which m1-01 started.

## Contract
- `packages/db` already has the durable port from m1-01. This slice replaces m1-01's minimal `withTenant` helper.
- Dependency: `pg` (already pinned by m1-01). No ORM.
- Plain SQL migrations in `packages/db/migrations/NNNN_name.sql`, applied in order, checksummed in `schema_migrations`.
- Config: `packages/db/src/config.ts` reads `OFFLOAD_RAW_TTL_DAYS` (default 30), `OFFLOAD_TEXT_TTL_DAYS` (default 7),
  `OFFLOAD_CONTENT_TTL_DAYS` (default 30), `DATABASE_URL`. No other module hard-codes these numbers.
- Tables (fields exactly as in DATA_MODEL.md): `tenants`, `workspaces`, `members`, `workspace_members`, `sessions`,
  `devices`, `device_nonces`, `device_enrollment_codes (tenant_id, code_sha256) member_id, code_challenge,
  redirect_uri, expires_at (10 min), used_at`, `personal_access_tokens`, `pseudonym_key_wraps`, `idempotency_keys
  (tenant_id, key) request_sha256, status, response jsonb, created_at` (24 h), `magic_links` (global), `exclusions`, `imports`, `ingest_batches` (with
  `body_sha256`), `observations`, `observation_texts`, `audit_events`, `audit_anchors`, `purge_log`, `purge_requests`,
  `events_outbox`, `outbox_deliveries`, `schema_migrations`, `license_state` (with `seats`, `issued_at`).
- **Partitioning**: `observations` and `observation_texts` have `day date NOT NULL` (UTC date of `ts`, set by the
  server) and are `PARTITION BY RANGE (day)`; primary key `(tenant_id, device_id, object_id, day)`. A `DEFAULT`
  partition exists. `ensurePartitions(tx, fromDay, days)` creates daily partitions and runs `ENABLE` + `FORCE ROW
  LEVEL SECURITY` and both policies on each one at creation (child partitions do not inherit FORCE).
- **Tenant RLS**: every table in schema `public` with `tenant_id` has `ENABLE` + `FORCE ROW LEVEL SECURITY` and policy
  `tenant_isolation USING (tenant_id = nullif(current_setting('app.tenant_id', true), '')::uuid) WITH CHECK (same)`.
  `tenants` itself: `USING (id = app.tenant_id)`. Global allowlist (no RLS): `schema_migrations`, `license_state`, `magic_links`
  (no tenant data: a hashed email and token only), and everything in schema `durable`.
- **Member isolation** (restrictive) on every C1, C2 and C6 table created here (`observations`, `observation_texts`,
  `imports`, `exclusions`): `CREATE POLICY member_isolation AS RESTRICTIVE USING (member_id =
  nullif(current_setting('app.member_id', true), '')::uuid OR current_setting('app.member_scope', true) = 'tenant')`.
  The list of member-isolated tables is exported as `MEMBER_ISOLATED_TABLES` and later slices append to it.
- **Roles**: `offload_migrator` (owner of everything); `offload_app` (not owner, no `BYPASSRLS`, no DELETE on the
  append-only set); `offload_retention` (DELETE on expired rows and DROP of expired partitions only); `offload_jobs`
  (cross-tenant jobs: EXECUTE on `jobs_list_tenants()` and `outbox_claim(limit int)` only).
- **Append-only set** (one list, as DATA_MODEL section 1): `audit_events`, `audit_anchors`, `purge_log` get a trigger
  refusing UPDATE, DELETE and TRUNCATE for every role except `offload_retention`. (`item_journal`,
  `item_journal_transitions`, `budget_entries`, `approvals` join the list in M2 with the same trigger function
  `refuse_mutation()`.)
- **Resolver functions** (`SECURITY DEFINER`, owned by `offload_migrator`, `SET search_path = public`, return ids only,
  zero rows for unknown keys; `offload_app` has EXECUTE):
  `auth_resolve_identity(idp_subject text) → (tenant_id, member_id)`,
  `auth_resolve_session(token_sha256 text) → (tenant_id, member_id, tenant_role, expires_at, last_seen_at)`,
  `auth_resolve_device(device_id uuid) → (tenant_id, member_id, revoked_at)`,
  `auth_resolve_enrollment_code(code_sha256 text) → (tenant_id, member_id, code_challenge, redirect_uri, expires_at,
  used_at)`,
  `auth_resolve_pat(token_sha256 text) → (tenant_id, member_id, scopes, revoked_at)`.
  `jobs_list_tenants() → (tenant_id)`; `outbox_claim(limit int) → setof (tenant_id, id)` (marks claimed via
  `outbox_deliveries`).
- `withTenant({ tenantId, principalId, memberId, tenantRole, memberScope? = 'member' }, fn)` opens one transaction and
  runs `SET LOCAL app.tenant_id`, `app.principal_id`, `app.member_id`, `app.tenant_role`, `app.member_scope`.
  **No network I/O inside `fn`**: `withTenant` passes `fn` a `tx` only; in tests a guard patches `globalThis.fetch`
  for the duration and throws.
- `appendAudit(tx, event)` in `packages/db/src/audit.ts`: takes `pg_advisory_xact_lock(hashtextextended('audit:' ||
  tenant_id, 0))` as the last statement before its insert; `hash = sha256Hex(prev_hash || jcs(event_without_hash))`
  where `prev_hash` is the previous 64-char lowercase hex (ASCII) or 64 zeros for the first event; `seq` per tenant;
  `UNIQUE (tenant_id, prev_hash)`. `action` matches `^[a-z_]+\.[a-z_]+$`. `details` holds ids and hashes only.
- `createPersonalTenant(tx, { idpSubject, email })`: tenant `kind = 'personal'`, one workspace, one `owner` member,
  `email` stored and `email_hash = sha256Hex(lowercase(trim(email)))`; sets `app.tenant_id` to the new id before
  inserting (tenants RLS). Audit `tenant.created`.
- `setMemberRole(tx, memberId, role)`, `setMemberState(tx, memberId, state)`: throw `LastOwnerError { code:
  "last_owner" }` when the change would leave no active owner.
- `packages/testkit`: `pgTenantFixture()` (two tenants, two members each, real Postgres), `onBeforeCommit(hook)` fault
  injection that throws inside the transaction before COMMIT.
- Tests need a real Postgres 17 at `DATABASE_URL`. PGlite is not used for this slice.

## Red tests
Folder: `packages/db/tests/m1-03-tenancy-rls/`.

| Tag | Test name | Asserts |
|---|---|---|
| MIGRATE | MIGRATE: migrations apply in order on an empty database | |
| MIGRATE | MIGRATE: a changed applied migration fails its checksum | |
| MIGRATE | MIGRATE: observations is partitioned by day with the day in the primary key | `(tenant_id, device_id, object_id, day)`; `ON CONFLICT` on it works |
| MIGRATE | MIGRATE: an insert for a day with no partition lands in DEFAULT | |
| MIGRATE | MIGRATE: ensurePartitions forces RLS on every new partition | |
| RLS | RLS: every tenant table has FORCE ROW LEVEL SECURITY | `pg_class` in schema `public`, `relkind IN ('r','p')`, including partitions; allowlist only `schema_migrations`, `license_state`, `magic_links` |
| RLS | RLS: offload_app with tenant A reads zero rows of tenant B | for every tenant table |
| RLS | RLS: with app.tenant_id unset offload_app reads zero rows | |
| RLS | RLS: inserting a row for another tenant fails WITH CHECK | |
| RLS | RLS: tenants is isolated by id | |
| RLS | RLS: member B reads zero C1 rows of member A in the same tenant | every table in `MEMBER_ISOLATED_TABLES` |
| RLS | RLS: member_scope tenant reads every member's rows | |
| ROLE | ROLE: offload_app cannot DELETE or UPDATE audit_events, audit_anchors or purge_log | |
| ROLE | ROLE: offload_app has no BYPASSRLS and owns no table | |
| ROLE | ROLE: resolver functions return ids only and nothing for unknown keys | each of the five; result columns are exactly the listed ones |
| ROLE | ROLE: offload_jobs can list tenants and claim outbox rows and nothing else | SELECT on any table is denied |
| ROLE | ROLE: the fixture's role logins carry a generated test password, so they connect under scram-sha-256 auth | every role has a SCRAM verifier; each pool's `session_user` is its role |
| ROLE | ROLE: createPersonalTenant makes one tenant, one workspace, one owner | `email_hash` is sha256 of the trimmed lowercase email |
| ROLE | ROLE: removing the last owner throws LastOwnerError | `setMemberRole` and `setMemberState` |
| ROLE | ROLE: a fetch inside withTenant throws | no network I/O inside the transaction |
| AUDIT | AUDIT: appendAudit chains hash = sha256Hex(prev_hash + JCS(event)) | first event uses 64 zeros |
| AUDIT | AUDIT: two concurrent appends for one tenant produce one chain | `UNIQUE (tenant_id, prev_hash)` never violated; seq has no gap |
| AUDIT | AUDIT: an audit row rolls back with its transaction | `onBeforeCommit` throws; no row |
| AUDIT | AUDIT: an action not matching the pattern is refused | `Build.Approved` fails |
| AUDIT | AUDIT: details with a string longer than 128 characters are refused | ids and hashes only |

## Out of scope
HTTP routes, device auth, user-model tables (M5), routine tables (M2), the scheduled retention workflow (m3-01).

## Verify
`bash slices/m1-03-tenancy-rls/verify.sh` (needs `DATABASE_URL`).

## Scope changes
- RLS allowlist: the Contract and DATA_MODEL.md list `magic_links` as global with no RLS (it holds no tenant data and
  is read before a tenant is known); the red-test row listed only `schema_migrations` and `license_state`. The row now
  lists all three. ADR 0013 still names two; `docs/adr/**` is out of scope, so that is an open issue for the owner.
- `withTenant` takes the pool first: `withTenant(pool, ctx, fn)`, as m1-01's helper did; `memberId` may be `null` for
  service work. m1-01's `packages/db/src/durable/tenant.ts` is removed and the durable runtime calls the new helper.
- Added an AUDIT test for `verifyAuditChain` (edit, delete, fork), required by SECURITY_PRIVACY.md section 13 for this
  slice, and a MIGRATE test for `config.ts`.
- Review fixes: the `SECURITY DEFINER` functions use `search_path = pg_catalog, public, pg_temp` rather than
  `public` alone, because `public` alone leaves `pg_temp` searched first and a temp table could shadow a table. The
  resolver test checks for that value. Resolvers also skip frozen and departed members. Seven more tests pin the
  review findings (`review.test.ts`).
- The chain writer is written fresh from ADR 0018: no old-repo code was copied, so OQ-12 relicensing is not needed
  for it and `NOTICE` is unchanged.
- CI fix (password auth): CI's Postgres uses scram-sha-256, and the fixture connected as the four roles with no
  password (it had only run against trust auth). `@offload/testkit` now gives each role a test-only password,
  `testRolePassword(role)`: sha256 of the cluster address, the administrator's credentials and the role name, never
  stored or printed, the same for every process and database on one cluster. `freshDatabase` sets it (only when the
  stored SCRAM verifier differs, so concurrent runs do not race on `pg_authid`) and `roleUrl` carries it. Product code
  is unchanged: `bootstrapRoles` still leaves passwords to the operator. A ROLE test pins it. `pgTenantFixture` ends its
  pools when tenant setup fails. m1-01's durable test sets `offload_migrator`'s password with the same helper instead of
  a random one, so it no longer breaks a concurrent fixture run on a password-auth cluster.
