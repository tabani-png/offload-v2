# API contracts

The source of truth for every shape is `packages/contracts` (zod, exported to JSON Schema 2020-12)
([ADR 0008](adr/0008-contracts-first.md)). This document is the human index of those contracts. When they disagree, fix
this document in the same slice that changes the contract. Words follow [GLOSSARY.md](GLOSSARY.md); tables are in
[DATA_MODEL.md](DATA_MODEL.md).

Marking: **core** endpoints are in the open core. **ee** endpoints exist only when the Enterprise composition root is
running with a valid license key ([ADR 0015](adr/0015-open-core-layout-and-license-gating.md)).

## 1. Conventions

- **Base URL**: `https://<host>/v1`. JSON only (`application/json; charset=utf-8`), except SSE streams and keyframe upload.
- **Versioning**: breaking changes get a new path version (`/v2`). Additive fields are allowed within `v1`; clients
  ignore unknown fields. Events carry `type` and `version`.
- **Auth**:
  - Member session: cookie `__Host-offload_session` + header `X-CSRF-Token` on mutations (web and Mac UI).
  - Device: `Authorization: Bearer <device token>` (ES256 JWT, 15 min, audience `device`) + `Offload-Signature` on ingest.
  - Service and MCP clients: `Authorization: Bearer <personal access token>` (scoped, hashed at rest, revocable).
- **Idempotency**: every POST that creates something accepts `Idempotency-Key` (ULID). The same key with the same body
  returns the first response for 24 hours; with a different body returns `409 idempotency_conflict`. Ingest is
  idempotent by object id instead.
- **Pagination**: `?limit=` (max 200) and `?cursor=`; responses carry `next_cursor`.
- **Time**: RFC 3339 with offset. Days `YYYY-MM-DD`, weeks `YYYY-Www`, months `YYYY-MM`, quarters `YYYY-Qn`.
- **Rate limits**: `429` with `Retry-After`.

### Error envelope

```json
{ "error": { "code": "hash_mismatch", "message": "brief_hash does not match the current brief", "request_id": "req_01J..." } }
```

| HTTP | Codes |
|---|---|
| 400 | `invalid_request`, `unknown_kind`, `schema_invalid` |
| 401 | `unauthenticated`, `token_expired` |
| 403 | `forbidden`, `policy_denied` (with `rule_id`), `feature_not_licensed`, `hash_mismatch`, `consent_missing` |
| 404 | `not_found` |
| 409 | `already_running`, `approval_used`, `approval_expired`, `idempotency_conflict`, `seq_replay`, `last_owner`, `state_conflict` |
| 413 | `too_large` |
| 422 | `leak_detected`, `teeth_gate_failed`, `budget_exceeded` |
| 429 | `rate_limited` |
| 5xx | `server_error` |

### Figure

Every number in a response is a `Figure` ([ADR 0003](adr/0003-numbers-come-from-code.md)):

```json
{
  "value": 3.1, "unit": "hours_per_week",
  "arithmetic": "6 times × 31 min median = 3.1 h",
  "evidence": [{ "kind": "episode", "id": "ep_01J..." }],
  "source_purged_at": null
}
```

`GET /v1/figures/{figure_id}/evidence` returns the evidence rows ("how it was counted").

## 2. Public REST

### Auth and me (core)

| Method and path | Request | Response |
|---|---|---|
| `GET /auth/login?return_to=` | | 302 to the OIDC provider |
| `GET /auth/callback` | OIDC code | 302, sets session cookie |
| `POST /auth/logout` | | 204 |
| `GET /v1/me` | | `{ member, tenant, workspaces[], tenant_role, features[] }` |
| `POST /v1/me/tokens` | `{ name, scopes[] }` | `{ id, token }` (shown once) |

### Tenancy (core; SCIM and SSO are ee)

| Method and path | Request | Response |
|---|---|---|
| `GET /v1/tenant` · `PATCH /v1/tenant` | `{ name?, reporting_timezone?, monthly_model_budget_usd? }` | `Tenant` |
| `GET /v1/workspaces` · `POST /v1/workspaces` | `{ name }` | `Workspace` |
| `POST /v1/members/invite` | `{ email, tenant_role, workspace_ids[] }` | `Member` |
| `PATCH /v1/members/{id}` | `{ tenant_role?, state? }` | `Member` (409 `last_owner`) |
| `/scim/v2/Users`, `/scim/v2/Groups` (**ee**) | SCIM 2.0 | SCIM 2.0 |
| `GET/PUT /v1/sso/config` (**ee**) | `{ saml_metadata_url, enforced }` | `SsoConfig` |

### Devices (core)

| Method and path | Request | Response |
|---|---|---|
| `POST /v1/devices/enroll` | `{ code, code_verifier, public_jwk, name }` (PKCE S256, loopback redirect `http://127.0.0.1:<port>/callback`) | `{ device_id }` |
| `POST /v1/devices/challenge` | `{ device_id }` | `{ nonce, expires_at }` |
| `POST /v1/devices/token` | `{ device_id, nonce, signature }` | `{ token, expires_at }` (15 min) |
| `GET /v1/devices` · `DELETE /v1/devices/{id}` | | `Device[]` · 204 |

### Profile and privacy (core)

| Method and path | Request | Response |
|---|---|---|
| `GET /v1/profile` | | `Profile` |
| `PATCH /v1/profile` | partial `Profile`; goals ≤ 3, each ≤ 80 chars, one line; enums checked | `Profile` (400 `schema_invalid`) |
| `GET /v1/exclusions` · `POST` · `DELETE /v1/exclusions/{id}` | `{ kind, value }` | `Exclusion` |
| `GET /v1/me/export` | | 202 `{ export_id }`; then `GET /v1/me/export/{id}` → signed URL to JSON |
| `POST /v1/me/forget` | `{ scope: "entity" \| "range" \| "all" \| "import", entity_id?, from?, to?, import_id? }` | 202 `{ purge_id }` |
| `POST /v1/entities/{id}/confirm-name` | `{ name }` or `{ dont_track: true }` | `Entity` |
| `POST /v1/learning/pause` · `/resume` | | `Profile` |

### Today, records and review (core)

| Method and path | Response |
|---|---|
| `GET /v1/today?date=` | `{ day_grid: { categories[], cells[], switch_bursts[] }, what_you_did[], repeats[] (Figure each), suggested_fix: Opportunity \| null }` |
| `GET /v1/records/days/{date}` | `DayRecord` |
| `GET /v1/records/weeks/{iso_week}` | `WeekRecord` (404 for a future week) |
| `GET /v1/records/months/{month}` | `MonthRecord` |
| `GET /v1/records/quarters/{quarter}` | `QuarterRecord` |
| `GET /v1/review/week?w=` | `{ sentence, tiles[] (Figure), goals[], questions[] }` |
| `POST /v1/review/answers` | body `{ iso_week, subject_key, question_kind, answer, goal_id? }` → `ReviewAnswer` |
| `GET /v1/figures/{figure_id}/evidence` | `{ arithmetic, evidence[], source_purged_at }` |

### Opportunities, fixes and builds (core)

| Method and path | Request | Response |
|---|---|---|
| `GET /v1/opportunities?state=open` | | `Opportunity[]` with `factors` (Figures) and `options[]` |
| `GET /v1/opportunities/{id}` | | `Opportunity` |
| `POST /v1/opportunities/{id}/answer` | `{ answer: "build" \| "not_now" \| "never" \| "leave_alone", option_id? }` | `Opportunity` (state `chosen` → `designing` for build kinds) |
| `GET /v1/fixes/{id}` | | `Fix` with `brief`, `brief_hash`, `check_set_hash`, `held_out_hash`, `fixture_set_hash`, `estimate`, `cap_usd` |
| `POST /v1/fixes/{id}/build-approvals` (**OK, build**) | `{ brief_hash, check_set_hash, held_out_hash, fixture_set_hash, cap_usd: 4.00 }` | 202 `{ build_id }`; 403 `hash_mismatch`; 409 `already_running`; 403 `policy_denied` |
| `GET /v1/builds/{id}` | | `Build` with `state`, `spent_usd`, `cap_usd`, `stages[]`, `attempts[]`, `check_groups[]` |
| `GET /v1/builds/{id}/events` | | SSE: `build.stage`, `build.check_result`, `build.attempt_finished`, `build.spend`, `build.finished` |
| `POST /v1/builds/{id}/cancel` | | `Build` |
| `POST /v1/builds/{id}/deploy` (**deploy approval**) | `{ artifact_sha256, receipt_hash }` | 201 `{ routine_id, version }`; 403 `hash_mismatch`; 409 `state_conflict` unless `ready` |
| `GET /v1/builds/{id}/receipt` | | `{ receipt, receipt_hash, signature, key_id }` |

### Routines, runs and batches (core)

| Method and path | Request | Response |
|---|---|---|
| `GET /v1/routines` · `GET /v1/routines/{id}` | | `Routine` (with `commit_mode`, `clean_run_streak`) |
| `POST /v1/routines/{id}/pause` · `/resume` · `/retire` | | `Routine` |
| `POST /v1/routines/{id}/graduation` | `{ decision: "accept" \| "decline", approval_id }` | `Routine` |
| `GET /v1/routines/{id}/runs` · `GET /v1/runs/{id}` | | `Run` |
| `GET /v1/batches/{batch_hash}` | | `Batch` with items (real values restored, visible to approvers only) |
| `POST /v1/batches/{batch_hash}/approve` | `{ item_hashes?: [] }` (subset allowed) | `Batch`; 403 `hash_mismatch` |
| `POST /v1/batches/{batch_hash}/reject` | `{ reason? }` | `Batch` |
| `POST /v1/items/{id}/release` | | `Item` (only from `unknown`) |
| `POST /v1/kill-switches` · `DELETE /v1/kill-switches/{id}` | `{ scope, scope_id }` | `KillSwitch` |

### Connections (core)

| Method and path | Request | Response |
|---|---|---|
| `GET /v1/connections` | | `Connection[]` (no secrets) |
| `POST /v1/connections` | `{ adapter, provider, workspace_id, personal: bool }` | `{ connection_id, authorize_url? }` |
| `DELETE /v1/connections/{id}` | | 204 (credential crypto-shredded) |
| `GET /v1/capabilities` | | `Capability[]` with argument schemas and step class |

### Metrics, audit and policy

| Method and path | Plan | Response |
|---|---|---|
| `GET /v1/metrics/hours-saved?scope=&period=` | core | `HoursSavedReport` (hs-1, floor of 5 for groups) |
| `GET /v1/audit-events?cursor=` | core | `AuditEvent[]` |
| `GET /v1/audit-events/verify` | core | `{ ok, checked, first_bad_seq? }` |
| `POST /v1/audit-exports` · `GET /v1/audit-exports/{id}` | **ee** | `{ export_id, url }` |
| `PUT /v1/audit-streams/{id}` | **ee** | SIEM sink config |
| `GET /v1/policies` | core | built-in and custom policies (read) |
| `PUT /v1/policies/{id}` · `POST /v1/policies/simulate` | **ee** | `Policy` · `{ decisions[] }` over past runs |
| `GET /v1/budget?scope=` | core | spend by scope from `budget_entries` |

## 3. Device ingest

[ADR 0020](adr/0020-device-ingest-protocol.md). Core.

| Method and path | Body | Response |
|---|---|---|
| `POST /v1/ingest/batches` | `IngestEnvelope` (JCS bytes) | `IngestReceipt` |
| `POST /v1/ingest/keyframes` | `multipart/form-data`: `meta` (JSON `KeyframeMeta`, signed) + `image` (JPEG ≤ 512 KiB) | `IngestReceipt`; 403 `consent_missing` unless `keyframes_to_cloud` |
| `GET /v1/ingest/config` | | `{ flush_seconds: 300, max_objects: 500, max_bytes: 1048576, exclusions[], keyframes_to_cloud }` |

```json
{
  "v": 1,
  "device_id": "dev_01J...",
  "seq": 1842,
  "sent_at": "2026-11-14T16:05:00-05:00",
  "kind": "observation_batch",
  "objects": [
    { "id": "01JC...", "ts": "2026-11-14T16:01:12-05:00", "kind": "focus",
      "app_bundle_id": "com.todesktop.cursor", "app_name": "Cursor", "title": "offload-v2 · ARCHITECTURE.md", "host": null },
    { "id": "01JC...", "ts": "2026-11-14T16:02:00-05:00", "kind": "input_counts", "keys": 212, "clicks": 9 },
    { "id": "01JC...", "ts": "2026-11-14T16:02:30-05:00", "kind": "text_snapshot",
      "text": "Reply to <person:qkzt.1.first> about the invoice", "text_hash": "9f2c..." }
  ]
}
```

Headers: `Authorization: Bearer <device token>`, `Offload-Signature: keyid=<device_id>, sig=<base64url>`.
Upload kinds (closed set): `observation_batch`, `review_event`, `notice_ack`, `keyframe`.

`IngestReceipt`: `{ "accepted": ["01JC..."], "rejected": [{ "id": "01JC...", "code": "leak_detected" }] }`.
Rejection codes: `schema_invalid`, `leak_detected`, `excluded`, `too_old`, `unknown_kind`, `consent_missing`,
`rate_limited` (retryable), `server_error` (retryable).

## 4. Offload MCP server

Core. Streamable HTTP at `/mcp`, auth by personal access token with scope `mcp`. Read and propose only; no tool commits
anything outside Offload ([ADR 0010](adr/0010-mcp-first-connectors.md)).

| Tool | Input | Output |
|---|---|---|
| `offload.get_today` | `{ date? }` | Today payload (Figures) |
| `offload.get_week_record` | `{ iso_week }` | `WeekRecord` |
| `offload.list_opportunities` | `{ state? }` | `Opportunity[]` |
| `offload.search_episodes` | `{ query, from?, to?, limit? }` | `Episode[]` (masked) |
| `offload.list_routines` | `{}` | `Routine[]` |
| `offload.get_build` | `{ build_id }` | `Build` |
| `offload.propose_opportunity` | `{ title, description, task_key? }` | `Opportunity` in state `open` with `source: "agent"`; ranked like any other |

Tool results are masked text. Inputs are untrusted and validated against the schema.

## 5. Webhooks

**Inbound** (core): `POST /v1/hooks/{trigger_id}`. Header `Offload-Webhook-Signature: t=<unix>, v1=<hex HMAC-SHA256 of "t.body">`
with the trigger's secret; reject if `|now − t| > 300 s`. Body ≤ 256 KiB, treated as untrusted input to the routine.
Response `202 { run_id }`.

**Outbound** (core): tenants register endpoints for event types. Same signature scheme with the endpoint secret.
Retries with exponential backoff for 24 hours. Payload = the internal event envelope below, with masked fields only.

| Method and path | Request | Response |
|---|---|---|
| `GET /v1/webhook-endpoints` · `POST` · `DELETE /v1/webhook-endpoints/{id}` | `{ url, event_types[] }` | `{ id, secret }` (secret shown once) |

## 6. Internal events

Written to `events_outbox` in the same transaction as the change; delivered to durable workflows and outbound webhooks.

```json
{ "id": "evt_01J...", "type": "build.ready", "version": 1, "tenant_id": "...", "at": "2026-11-14T16:40:00Z",
  "subject": { "kind": "build", "id": "..." }, "data": { } }
```

| Type | Emitted by | Data |
|---|---|---|
| `observations.ingested` | api (ingest) | `{ device_id, member_id, count, first_ts, last_ts }` |
| `day.closed` | brain | `{ member_id, day }` |
| `records.updated` | brain | `{ member_id, kind: "day" \| "week" \| "month" \| "quarter", key }` |
| `opportunity.ranked` | brain | `{ member_id, iso_week, opportunity_ids[] }` |
| `opportunity.chosen` | api | `{ opportunity_id, fix_id }` |
| `fix.ready_for_approval` | brain | `{ fix_id, brief_hash, check_set_hash, held_out_hash, fixture_set_hash }` |
| `build.approved` | api | `{ build_id, approval_id }` |
| `build.attempt_finished` | builder | `{ build_id, attempt_id, ordinal, outcome }` |
| `build.ready` · `build.failed` · `build.capped` · `build.tampered` | builder | `{ build_id, spent_usd }` |
| `routine.deployed` | api | `{ routine_id, version, artifact_sha256 }` |
| `run.batch_ready` | runtime | `{ run_id, batch_hash, item_count }` |
| `run.finished` | runtime | `{ run_id, state }` |
| `saving.measured` | runtime | `{ run_id, saved_seconds, grade }` |
| `policy.graduation_proposed` | runtime | `{ routine_id, clean_run_streak }` |
| `breaker.tripped` | runtime | `{ routine_id, reason }` |

## 7. Core and EE summary

| Surface | Core | EE |
|---|---|---|
| Auth, me, devices, profile, privacy, today, records, review, opportunities, fixes, builds, routines, batches, connections, metrics, audit read/verify, policies read, budget, ingest, MCP, webhooks | yes | |
| SCIM, SSO config, audit exports and streams, policy write and simulate | | yes |
