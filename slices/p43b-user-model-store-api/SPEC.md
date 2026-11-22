---
id: p43b-user-model-store-api
title: User model storage in Postgres with tenant and member RLS, a repository, the member update job and framework-agnostic handlers for /v1/profile, /v1/records and /v1/review (port of old PR #43)
milestone: M5
status: done
depends_on: [p43a-user-model-core]
parallel_safe: false
human_gated: false
model_tier: opus
size: L
parallel_group: M5-B
owns: [services/brain/**]
verify: bash slices/p43b-user-model-store-api/verify.sh
min_tests: 20
paths_in_scope: [services/brain/**, slices/p43a-user-model-core/**, slices/p43b-user-model-store-api/**, NOTICE, docs/API.md, docs/DATA_MODEL.md, docs/MIGRATION.md]
paths_out_of_scope: [ee/**, apps/**, packages/**, services/api/**, services/runtime/**, services/broker/**, services/builder/**, docs/adr/**, .github/**, package.json, bun.lock]
red_tests: [PROFILE, API, PRIVACY, RLS, MERGE, INVALIDATE, STORE]
---

# p43b-user-model-store-api

## Summary
Stores the user model of [p43a](../p43a-user-model-core/SPEC.md) in Postgres 17 (the `R-model` tables of
[DATA_MODEL section 4](../../docs/DATA_MODEL.md#4-user-model) and `opportunities`), with tenant RLS and the restrictive
member wall of [ADR 0013](../../docs/adr/0013-tenancy-and-rls.md), and serves `GET/PATCH /v1/profile`,
`GET /v1/records/*`, `GET /v1/review/week` and `POST /v1/review/answers` as web-standard `Request → Response` handlers
that `services/api` mounts later ([API.md](../../docs/API.md#profile-and-privacy-core)). Moves the M5 exit criteria
"the weekly review lands" and "answers change next week's ranking". Design and stubs:
[p43a DESIGN.md](../p43a-user-model-core/DESIGN.md).

## Contract
- No new dependency: Postgres through Bun's built-in `SQL`.
- Migrations: `services/brain/sql/0001_user_model.sql` (plain SQL, unqualified names, grants to `offload_app`).
  `applyUserModelMigrations(sql, { schema, appRole })` applies them into one schema; `packages/db`'s migration runner
  adopts the files later and adds the FKs to `tenants`, `members` and `workspaces`.
- Tables (fields as DATA_MODEL): `profiles`, `goals` (at most 3 active, enforced by a trigger), `task_ledger`,
  `episodes`, `propositions` (one current version per key; `invalid_at ≥ valid_at`), `day_records`, `week_records`,
  `month_records`, `quarter_records`, `figure_index`, `review_answers`, `opportunities`. Each has `tenant_id`,
  `member_id`, `ENABLE` + `FORCE ROW LEVEL SECURITY`, `tenant_isolation` and `member_isolation AS RESTRICTIVE`.
  `offload_app` has SELECT, INSERT, UPDATE; DELETE only on `figure_index` and `opportunities`. Vectors are `real[]`
  until pgvector is installed. `MEMBER_ISOLATED_TABLES` lists them.
- `RunInTenant` port and `bunRunInTenant(sql, { schema?, appRole? })`: one transaction with `SET LOCAL app.tenant_id`,
  `app.member_id`, `app.principal_id`, `app.tenant_role`, `app.member_scope` (stands in for `withTenant`).
- Repository (`src/store/repository.ts`): profile and goals, task ledger, episodes, day/week/month/quarter records
  (each figure indexed in `figure_index`), propositions (upsert by id, never delete), review answers (latest wins),
  opportunities, `markSourcePurged(day, at)`. A write whose text holds an email address or a URL is refused.
- Job (`src/store/job.ts`): `runMemberUpdate(tx, input)` runs the p43a pipeline for one window and saves it; running
  it twice with the same window leaves the same rows.
- Handlers (`src/http/handlers.ts`): `handleUserModelRequest(req, auth, deps)` returns a `Response` for the routes
  below and `null` for any other path. Errors use the API.md envelope `{ error: { code, message, request_id } }`.

| Route | Success | Errors |
|---|---|---|
| `GET /v1/profile` | 200 `Profile` (defaults when none stored) | |
| `PATCH /v1/profile` | 200 `Profile` | 400 `schema_invalid` |
| `GET /v1/records/days/{date}` | 200 `DayRecord` | 400 `invalid_request`, 404 `not_found` |
| `GET /v1/records/weeks/{iso_week}` | 200 `WeekRecord` | 400, 404 (future week or none) |
| `GET /v1/records/months/{month}` · `/quarters/{quarter}` | 200 | 400, 404 |
| `GET /v1/review/week?w=` | 200 `{ iso_week, sentence, tiles[], goals[], questions[] }` | 400, 404 (future week or none) |
| `POST /v1/review/answers` | 200 `ReviewAnswer` | 400 `schema_invalid` (shape), 400 `invalid_request` (unknown goal, future week) |

## Red tests (write these first, run them, see them fail)
Folder: `services/brain/tests/p43b-user-model-store-api/`. Real Postgres 17 at `DATABASE_URL`; each file creates and
drops its own schema and roles.

| Tag | Asserts |
|---|---|
| PROFILE | GET defaults; PATCH round-trips and bumps `version`; each validation case is 400 `schema_invalid`; goal ids stay the same for the same text; the database refuses a fourth active goal |
| API | review week 200 with Figure tiles; future week 404; malformed 400 with the error envelope; records days/weeks/months/quarters 200, 404, 400; answers stored, `not_now` takes the task out of the questions, bad answers 400; a goal answer sets alignment 1 at the next ranking; unknown paths return null |
| PRIVACY | no window title, text snapshot, URL or email from the fixture is in any R-model table |
| RLS | every table has forced RLS and both policies; member B reads zero rows of member A; tenant B reads zero rows of tenant A; inserting for another member fails |
| MERGE | the update job run twice with the same window leaves identical rows |
| INVALIDATE | an ended proposition stays as a row with `invalid_at` and `expired_at`; `offload_app` cannot DELETE propositions |
| STORE | a write with an email or URL is refused; every figure of a saved record resolves through `figure_index`; `markSourcePurged` keeps values and re-indexes figures |

## Out of scope
Mounting the routes in `services/api`, auth, CSRF and idempotency keys (W1-E). The durable workflow and schedule
that call the job (W1-C, m5-05). pgvector, forget and export (M7). `GET /v1/today` and `GET /v1/figures/*`.

## Verify
`bash slices/p43b-user-model-store-api/verify.sh` (needs `DATABASE_URL`).

## Scope changes
- `figure_index` is keyed by `(tenant_id, member_id, figure_id, record_kind, record_key)`, not `figure_id` alone, so a
  figure shared by two records survives re-indexing one of them; DATA_MODEL is corrected.
- `paths_in_scope` also lists `slices/p43a-user-model-core/**`: both slices stack on one branch and the last commit
  sets both to `done`.
