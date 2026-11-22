---
id: m3-05b-imports-server
title: Server half of the recordings import - open and list import spaces, ingest imported observations into their import space, forget scope import
milestone: M3
status: in_progress
depends_on: [m1-03-tenancy-rls, m1-04-login-devices, m3-01-ingest-batches]
parallel_safe: true
human_gated: false
model_tier: opus
size: M
parallel_group: M3-C
owns: [services/api/src/imports/**]
verify: bash slices/m3-05b-imports-server/verify.sh
min_tests: 20
paths_in_scope: [services/api/src/**, services/api/tests/m3-05b-imports-server/**, packages/contracts/src/**, packages/contracts/schemas/**, packages/contracts/scripts/**, packages/db/migrations/0007_imports.sql, slices/m3-05b-imports-server/**, docs/API.md, docs/DATA_MODEL.md, docs/ARCHITECTURE.md, docs/ROADMAP.md, docs/SECURITY_PRIVACY.md]
paths_out_of_scope: [ee/**, apps/**, services/brain/**, services/builder/**, services/runtime/**, services/broker/**, services/api/tests/m3-01-ingest-batches/**, .github/**, docs/adr/**]
red_tests: [IMPORT]
---

# m3-05b-imports-server

## Summary
The server half of the recordings import ([ROADMAP M3](../../docs/ROADMAP.md#m3-capture-to-cloud) task m3-05, the
item its SPEC recorded as a follow-up under "Scope changes"; [ARCHITECTURE section 2](../../docs/ARCHITECTURE.md),
"Recordings import"; [ADR 0020](../../docs/adr/0020-device-ingest-protocol.md), "Imported objects"). A member opens an
**import space** with `POST /v1/imports`, lists them with `GET /v1/imports`, the uploader sends masked observations with
`source = "import"` and that `import_id`, and `POST /v1/me/forget` with scope `import` wipes the import space as a unit.
Without it every imported object is `schema_invalid` (the end-to-end report of 2026-11-22, stage 2). It moves the M3
exit tests `IMPORT: forget import wipes every row with that import_id` and `IMPORT: an imported object older than 7 days
is accepted and its day is the ingest date`.

## Contract
No new dependency. New zod contracts in `packages/contracts/src/imports.ts` (exported to JSON Schema under
`packages/contracts/schemas/`: `open-import-request`, `import`, `forget-request`, `purge-request-state`):

```ts
ImportSourceKind = "screenwatch" | "screenshots" | "videos"            // DATA_MODEL imports.source_kind
OpenImportRequest = { source_kind: ImportSourceKind }                    // strict
OpenImportResponse = { import_id: uuid }
Import = { id: uuid, source_kind, first_day: "YYYY-MM-DD" | null, last_day: "YYYY-MM-DD" | null, created_at: rfc3339 }
ForgetRequest = { scope: "entity" | "range" | "all" | "import", entity_id?: uuid, from?: day, to?: day, import_id?: uuid }  // strict
ForgetResponse = { purge_request_id: uuid }
PurgeRequestState = { state: "queued" | "running" | "done" | "failed" }
```

Endpoints (docs/API.md "Profile and privacy"), member token or web session (CSRF on POST), every query inside
`withTenant` for the caller's member, so RLS (tenant wall and member wall on `imports`, `observations`,
`observation_texts`) scopes every row:

| Method and path | Request | Response |
|---|---|---|
| `POST /v1/imports` | `OpenImportRequest` | 201 `{ import_id }`; 400 `invalid_request` for anything else. Audit `import.opened` `{ source_kind }` |
| `GET /v1/imports` | | 200 `Import[]`, the member's own, newest first |
| `POST /v1/me/forget` | `ForgetRequest` with `scope: "import"` and `import_id` | 202 `{ purge_request_id }` (done before the answer); 404 `not_found` for an import that is not the caller's or is already forgotten; 400 `invalid_request` for scopes `entity`, `range`, `all` (M7) and a malformed body |
| `GET /v1/purge-requests/{id}` | | 200 `{ state }` for the caller's own request, else 404 |

Ingest (`POST /v1/ingest/batches`, `observation_batch`), changes to step 7 and 8 of ADR 0020:
- An object with `source = "import"` is accepted only with the `import_id` of an import space the device's member has
  opened and not forgotten; else `schema_invalid` (unchanged rule, now reachable). It skips `too_old`; its `day` is the
  UTC date of ingest (unchanged).
- New: an object with an `import_id` but no `source = "import"` is `schema_invalid` (it would sit in the live store and
  still be wiped by forget).
- New: the open import spaces are read again in the insert transaction under `FOR NO KEY UPDATE`, so a forget that commits
  between the check and the insert cannot leave orphan rows; objects of a vanished import space are then
  `schema_invalid` in the receipt.
- New: accepted imported objects widen `imports.first_day` / `last_day` to the UTC dates of their `ts` (the days the
  recordings show, for the analysis anchored to an import's last day).
- Changed outbox payload: one `observations.ingested` event per batch for its live objects (payload as before:
  `{ device_id, member_id, seq, accepted }`) and one per import space in the batch
  (`{ device_id, member_id, seq, accepted, import_id }`). Ids and counts only.

Forget scope `import`, one transaction (`withTenant`, member context): lock the `imports` row `FOR UPDATE`; delete
`outbox_deliveries` and `events_outbox` rows whose payload has this `import_id` and `member_id`; delete
`observations` and `observation_texts` with this `import_id` (every partition); delete the `imports` row; insert
`purge_requests` (`scope` `import`, `scope_ref` = import id, `state` `done`, `finished_at`), `purge_log`
(`rows_deleted` `{ observations, observation_texts, events_outbox, imports }`, `requested_by` = member id) and audit
`privacy.forgotten` `{ scope: "import", import_id, purge_request_id }`.

Migration `packages/db/migrations/0007_imports.sql`: partial indexes on `observations` and `observation_texts`
`(tenant_id, member_id, import_id) where import_id is not null`, and on `events_outbox`
`(tenant_id, (payload->>'import_id')) where payload ? 'import_id'`, so forget does not scan the live store or the outbox.

## Design note
- **Module**: `services/api/src/imports/` (`routes.ts` registers the four routes; `forget.ts` holds
  `forgetImport(tx, …)`, pure SQL on the open transaction, so the M7 durable forget can call it). `registerIngest`
  stays as is; `createApp` calls `registerImports` with the same `IngestDeps`.
- **Synchronous forget**: the import space is small (one folder of recordings) and every delete is by indexed
  `import_id`, so the purge runs inside the request and `purge_requests.state` is `done` when 202 returns. The 202 and
  the poll route keep the API.md shape, so M7's queued scopes need no client change.
- **Forget deletes the `imports` row** (the brief: "wipes every row with that import_id"); `wiped_at` stays unused
  here and is for M7's queued purge. A forgotten id is then unknown: ingest rejects it and forget answers 404.
- **Outbox**: deleting the import's events keeps a dispatcher from starting work for rows that are gone. Splitting the
  event per import space makes that delete exact (a batch with live objects keeps its live event).
- **Ingest race**: forget takes the `imports` row `FOR UPDATE`; the ingest insert transaction re-reads open import
  spaces `FOR NO KEY UPDATE` (not `FOR SHARE`: two devices of one member writing into one import space would each
  hold a share lock and deadlock on the `first_day`/`last_day` update), so batches and forget serialise on that row.
  Forget locks the import's outbox events `FOR UPDATE` before deleting deliveries, so a dispatcher holding one is
  waited for instead of racing the foreign key. Import ids are lower-cased on ingest and forget.
- **No Idempotency-Key** yet: no route in the repo implements `idempotency_keys`; opening two import spaces is harmless
  (an empty one is listed and can be forgotten). Recorded under Scope changes.

## Red tests (write these first, run them, see them fail)
Tests live in `services/api/tests/m3-05b-imports-server/`, real Postgres (the m3-01 harness), fake clock.

| Tag | Test name | Asserts |
|---|---|---|
| IMPORT | IMPORT: POST /v1/imports opens an import space for the member and audits it | 201 `{ import_id }` (uuid), row with `source_kind`, member, null days; audit `import.opened` with `source_kind` only |
| IMPORT | IMPORT: POST /v1/imports refuses an unknown source_kind, extra keys and a missing body with 400 invalid_request | nothing stored |
| IMPORT | IMPORT: the import routes need a member token or a session with CSRF | no auth 401; device-audience token 401; session without CSRF 403 |
| IMPORT | IMPORT: GET /v1/imports lists only the member's own import spaces, newest first | another member and another tenant are not listed; shape matches `ImportSchema` |
| IMPORT | IMPORT: an imported object older than 7 days is accepted and its day is the ingest date | ts 10 days ago accepted; stored `day` = ingest date, `ts` kept, `source` import, `import_id`; text snapshot too |
| IMPORT | IMPORT: accepted imported objects set the import's first_day and last_day from their ts | widened over two batches; GET shows them |
| IMPORT | IMPORT: an imported object whose import was never opened, is another member's or was forgotten is rejected schema_invalid | nothing stored |
| IMPORT | IMPORT: a live object that carries an import_id is rejected schema_invalid | |
| IMPORT | IMPORT: the outbox gets one observations.ingested event for live objects and one per import space | payloads ids and counts only |
| IMPORT | IMPORT: forget import wipes every row with that import_id | observations, observation_texts (incl. a daily partition), outbox events and their deliveries, the imports row: all 0 |
| IMPORT | IMPORT: forget leaves live rows, other import spaces and other members' imports alone | |
| IMPORT | IMPORT: forget writes a done purge request, a purge_log row with counts and an audit event with ids only | `GET /v1/purge-requests/{id}` → `{ state: "done" }`; another member's request 404 |
| IMPORT | IMPORT: forget for an unknown, already forgotten or another member's import is 404 and deletes nothing | incl. another tenant's import id |
| IMPORT | IMPORT: forget scopes other than import and malformed bodies are 400 invalid_request | `entity`, `range`, `all`, missing `import_id`, extra key |
| IMPORT | IMPORT: an import forgotten while its batch is being checked stores nothing for it | forget commits between the check and the insert (fault hook): receipt `schema_invalid`, 0 rows |
| IMPORT | IMPORT: the contracts accept the API.md bodies and the JSON Schemas agree | zod and committed JSON Schema |
| IMPORT | IMPORT: two devices of one member ingest into one import space at the same time without a deadlock | 15 concurrent rounds all 200 (review 1, finding 1) |
| IMPORT | IMPORT: an import_id sent in upper case is the same import space for ingest and forget | review 1, finding 4 |
| IMPORT | IMPORT: forget waits for a dispatcher that holds the import's outbox event and still wipes it | 202, no FK error (review 1, finding 2) |
| IMPORT | IMPORT: forget finds an import's outbox events through an index, not a scan of the outbox | review 1, finding 3 |

## Out of scope
The Mac sink and uploader (m3-02); forget scopes `entity`, `range`, `all` and `GET /v1/me/export` (M7); derived user
model rows built from an import (m5-01 and later must drop or recompute what they built from an import's
observations: they read `observations` by `import_id`/`ts`, and the outbox events are gone); purging durable workflow
state (none references an import yet); the analysis anchored to an import's last day (m5-01).

## Verify
`bash slices/m3-05b-imports-server/verify.sh` (needs `DATABASE_URL`, a disposable `*_test` database).

## Scope changes
- `packages/contracts/src/**` and `schemas/**` are in scope (ADR 0008: shapes in contracts first); the brief named
  services/api and a migration only.
- `Idempotency-Key` on `POST /v1/imports` is not built (no shared implementation exists yet); API.md notes it.
- `imports.wiped_at` is not written by this slice (the row is deleted); DATA_MODEL says so.
- The red test "an import forgotten while its batch is being checked" was made stricter after the red commit: its
  fault hook counted the device's token transactions too, so it forgot before the check, not between check and insert,
  and passed without the recheck. It now mints the token first; it fails with the recheck removed
  (spot-checked) and passes with it.
- API.md's `observations.ingested` payload row said `{ device_id, member_id, count, first_ts, last_ts }`, which m3-01
  never wrote; it now states the real payload plus `import_id`.

## Progress
- [x] SPEC, verify.sh, ROADMAP row (`8cdf499`)
- [x] red tests committed (`057ec31`), seen failing (16 of 16: routes 404, contracts missing)
- [x] contracts (`82e3061`); migration 0007, routes, ingest changes, forget (`080ea1c`)
- [x] docs (API.md, DATA_MODEL.md, ARCHITECTURE.md, SECURITY_PRIVACY.md)
- [x] review 1 (independent Opus read of SPEC, diff and tests; mutation spot-checks A to F): 1 major (deadlock between
  two devices' batches on one import space: `FOR SHARE` then `UPDATE`), 3 minor (forget vs dispatcher FK race,
  unindexed outbox lookup, upper-case import ids). All fixed, red tests first (`bd3683e`).
- [ ] a second review of the fixes and the CI run; status stays `in_progress` until then
