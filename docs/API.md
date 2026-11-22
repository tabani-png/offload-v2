# API contracts

The source of truth for every shape is `packages/contracts` (zod, exported to JSON Schema 2020-12)
([ADR 0008](adr/0008-contracts-first.md)). This document is the human index of those contracts. When they disagree, fix
this document in the same slice that changes the contract. Words follow [GLOSSARY.md](GLOSSARY.md); tables are in
[DATA_MODEL.md](DATA_MODEL.md).

Marking: **core** endpoints are in the open core. **ee** endpoints are mounted only by the Enterprise composition root
(`@offload-ee/server-ee`); there they return `403 feature_not_licensed` when the license key does not entitle the
feature. The core root does not mount them at all, so they are `404` there
([ADR 0015](adr/0015-open-core-layout-and-license-gating.md)). Endpoints without a milestone note land by M2; later ones
say when ([ROADMAP.md](ROADMAP.md)).

## 1. Conventions

- **Base URL**: `https://<host>/v1`. The browser login routes `/auth/*` and the health checks `/healthz` and `/readyz` are the
  exceptions: they sit outside `/v1` because they are redirects or operations checks, not API calls. JSON only (`application/json; charset=utf-8`), except SSE streams and
  keyframe upload.
- **Versioning**: breaking changes get a new path version (`/v2`). Additive fields are allowed within `v1`; clients
  ignore unknown fields. Events carry `type` and `version`.
- **Auth** ([ADR 0014](adr/0014-identity.md)):
  - **Web app**: session cookie `__Host-offload_session` + header `X-CSRF-Token` on mutations. `GET /v1/me` returns
    `csrf_token` (raw, once per session; only `sessions.csrf_sha256` is stored).
  - **Mac UI**: `Authorization: Bearer <device token>` with audience `member` (minted by the same challenge path as
    ingest tokens). No cookie, no idle logout. Approvals posted from the Mac (`build-approvals`, `deploy`, batch
    approve and reject, graduation, release) also carry `Offload-Signature` by the device key; the server verifies it
    and records `approvals.approver_device_id`.
  - A member token can call every `/v1` route a web session can (no CSRF header), including `GET/PATCH /v1/profile`,
    `/v1/exclusions`, `/v1/connections`, `/v1/imports` and `/v1/me/consents`. Owner-only routes still check the
    tenant role.
  - **Device** (ingest, device commands): `Authorization: Bearer <device token>` with audience `device` + `Offload-Signature`.
  - **Service and MCP clients** (M8): `Authorization: Bearer <personal access token>` (scoped, hashed at rest, revocable).
- **Device token**: ES256 JWT, 15 minutes, claims `tenant_id`, `member_id`, `device_id`, `aud` (`device` or `member`).
- **Signatures** (`Offload-Signature: keyid=<device_id>, sig=<base64url>`): ECDSA P-256 / SHA-256, encoded as the
  64-byte raw `r‖s` (JOSE / IEEE P1363; Swift `ECDSASignature.rawRepresentation`), base64url without padding. The
  signed bytes are the exact request body, and the body must equal `jcs(JSON.parse(body))`, else
  `400 invalid_request`. For `POST /v1/devices/token` the signed bytes are the UTF-8 of `nonce` as returned by the
  challenge endpoint. `device_id` is a uuid everywhere (token claim, envelope, `keyid`).
- **Idempotency**: every POST that creates something accepts `Idempotency-Key` (ULID), stored in `idempotency_keys`.
  The same key with the same body returns the first response for 24 hours; with a different body returns
  `409 idempotency_conflict`. Ingest is idempotent by object id instead.
- **Pagination**: `?limit=` (max 200) and `?cursor=`; responses carry `next_cursor`.
- **Time**: RFC 3339 with offset. Days `YYYY-MM-DD`, weeks `YYYY-Www`, months `YYYY-MM`, quarters `YYYY-Qn`.
- **Ids**: row ids are uuids; device objects are ULIDs; request ids are `req_` + ULID; figure ids are `fig_` + 16 hex
  ([DATA_MODEL.md section 1](DATA_MODEL.md#1-conventions)).
- **Rate limits**: `429 rate_limited` with `Retry-After`. Ingest: 60 requests per minute per device.
- **Untrusted text**: any text from tools, mail, web pages, webhook bodies or agents is wrapped as
  `<untrusted source="...">…</untrusted>` before any model sees it ([SECURITY_PRIVACY.md](SECURITY_PRIVACY.md#7-prompt-injection-defenses)).

### Error envelope

```json
{ "error": { "code": "policy_denied", "message": "commits are paused in quiet hours", "request_id": "req_01J...", "rule_id": "core.commit.quiet_hours" } }
```

`rule_id` is present only when a policy decided. The code list is closed:

| HTTP | Codes |
|---|---|
| 400 | `invalid_request`, `unknown_kind`, `schema_invalid`, `clock_skew` |
| 401 | `unauthenticated`, `token_expired` |
| 403 | `forbidden`, `policy_denied` (with `rule_id`), `feature_not_licensed`, `hash_mismatch`, `consent_missing` |
| 404 | `not_found` |
| 409 | `already_running`, `approval_used`, `approval_expired`, `idempotency_conflict`, `seq_replay`, `nonce_used`, `last_owner`, `state_conflict`, `stale_notice` |
| 413 | `too_large` |
| 422 | `leak_detected`, `teeth_gate_failed`, `budget_exceeded`, `recipient_not_allowed` |
| 429 | `rate_limited` |
| 5xx | `server_error` |

### Figure

Every number in a response is a `Figure` ([ADR 0003](adr/0003-numbers-come-from-code.md)). `source_purged_at` is
always present and may be null.

```json
{
  "id": "fig_3f9a0c1d2b4e5f60",
  "value": 3.1, "unit": "hours_per_week",
  "arithmetic": "6 times × 31 min median = 3.1 h",
  "evidence": [{ "kind": "episode", "id": "ep_01J..." }],
  "source_purged_at": null
}
```

`id` = `fig_` + first 16 hex of sha256(JCS(figure without `id`)). The server resolves it through `figure_index`.
`GET /v1/figures/{figure_id}/evidence` returns the evidence rows ("how it was counted").

## 2. Public REST

### Operations (core)

Outside `/v1`, like `/auth/*`: health checks for compose, Helm and the Offload Cloud deploy, the same in both hosting
modes ([ADR 0037](adr/0037-hosting-cloud-and-self-host-parity.md)). No auth, no content, no tenant data.

| Method and path | Response |
|---|---|
| `GET /healthz` | 200 `{ status: "ok" }` while the process runs (liveness) |
| `GET /readyz` | 200 `{ status: "ready", version, migration_head }` when Postgres, the object store and the broker are reachable and the schema is at the expected head; 503 `{ status: "not_ready", failing: ["postgres" \| "object_store" \| "broker" \| "migrations"] }` otherwise |

### Auth and me (core)

M1 login uses one OIDC provider (Google, his Workspace) or an email magic link for self-host. WorkOS AuthKit is the
Offload Cloud provider from M8 ([OQ-06](OPEN_QUESTIONS.md#oq-06-identity-provider-for-offload-cloud)).

| Method and path | Request | Response |
|---|---|---|
| `GET /auth/login?return_to=` | `return_to` must be a same-origin path starting with `/` (no scheme, no `//`), else 400 `invalid_request` | 302 to the OIDC provider |
| `GET /auth/callback` | OIDC code and state | 302 to `return_to` or `/`, sets session cookie; first login creates a personal tenant. 400 `invalid_request` when no login is in progress or the state differs; 401 `unauthenticated` when the provider or the ID token refuses |
| `POST /auth/magic-link` · `GET /auth/magic-link/callback?token=&email=` | `{ email, return_to? }` · token (32 random bytes, sha256 stored, single use, 15 min) and the email it was sent to | 204 (always, known email or not) · 302 to `return_to`, sets session (self-host). 401 `unauthenticated` for an unknown or used link, 401 `token_expired` after 15 minutes |
| `POST /auth/logout` | `X-CSRF-Token` when the session is live (else 403 `forbidden`) | 204; revokes the session and clears the cookie |
| `GET /v1/me` | session or member token | `{ member, tenant, workspaces[], tenant_role, features[], upload_consent, csrf_token? }` (`csrf_token` for web sessions only, on the first call of the session; `upload_consent` from M3, m3-01). `upload_consent`: `{ notice_id: "what-leaves-your-mac", current_version, consented_version \| null, needed: bool }`; `needed` is true when there is no consent for `current_version` |
| `POST /v1/me/consents` (M3) | `{ notice_id: "what-leaves-your-mac", notice_version, device_id }`; session or member token; `notice_version` must equal the current version, else 409 `stale_notice` | 201 `Consent`. Audited as `privacy.consent_given`. Upload consent for this member ([ONBOARDING screen 5](ONBOARDING.md#6-screens-4-and-5-sign-in-and-what-leaves-your-mac)) |
| `DELETE /v1/me/consents/what-leaves-your-mac` (M3) | session or member token | 204; sets `withdrawn_at`, audited as `privacy.consent_withdrawn`; uploads stop (Local mode) |
| `POST /v1/me/tokens` (M8) | `{ name, scopes[] }` | `{ id, token }` (shown once) |

### Tenancy (core; team tenants are ee from M8, decided in OQ-13; SCIM and SSO are ee)

| Method and path | Request | Response |
|---|---|---|
| `GET /v1/tenant` · `PATCH /v1/tenant` | `{ name?, reporting_timezone?, monthly_model_budget_usd? }` | `Tenant` |
| `GET /v1/workspaces` · `POST /v1/workspaces` (**ee**, M8) | `{ name }` | `Workspace` |
| `POST /v1/members/invite` (**ee**, M8) | `{ email, tenant_role, workspace_ids[] }` | `Invite` (token mailed, `token_sha256` stored, 7 days) |
| `POST /v1/invites/{token}/accept` (**ee**, M8) | | `Member` |
| `PATCH /v1/members/{id}` | `{ tenant_role?, state? }` | `Member` (409 `last_owner`) |
| `POST /v1/support-grants` · `DELETE /v1/support-grants/{id}` | `{ staff_principal, reason, expires_at }` (≤ 72 h; owner only) | `SupportGrant` · 204 |
| `/scim/v2/Users`, `/scim/v2/Groups` (**ee**, M9) | SCIM 2.0 | SCIM 2.0 |
| `GET/PUT /v1/sso/config` (**ee**, M9) | `{ saml_metadata_url, enforced, domains[] }` | `SsoConfig` |

**Implementation (m1-04).** Shapes are in `packages/contracts/src/auth` (`MeResponseSchema`, `MagicLinkRequestSchema`,
`DeviceEnrollRequestSchema`, `DeviceChallengeRequestSchema`, `DeviceTokenRequestSchema`, `DeviceSchema`).
- Config names: `OFFLOAD_PUBLIC_BASE_URL` (an https origin), `OFFLOAD_OIDC_ISSUER`, `OFFLOAD_OIDC_CLIENT_ID`,
  `OFFLOAD_OIDC_CLIENT_SECRET_REF`, `OFFLOAD_DEVICE_TOKEN_SIGNING_KEY_REF` (ES256 P-256 PKCS#8 PEM). A `_REF` is
  `file:<absolute path>` or `env:<NAME>`; the value is resolved at start and never logged. Without
  `OFFLOAD_OIDC_ISSUER`, `/auth/login` and `/auth/callback` are 404; without a mailer, the magic link routes are 404.
- OIDC: authorization code with PKCE S256 and a nonce; the state, nonce, verifier and `return_to` ride in a 10-minute
  `__Host-offload_login` cookie (httpOnly, Secure, SameSite=Lax), cleared at the callback. The ID token must verify
  against the provider's JWKS, carry the nonce and a verified email. `members.idp_subject` is `oidc|<issuer>|<sub>`,
  or `magic|<email_hash>` for magic links.
- Session token, csrf token, enrollment code, nonce and magic link token are each 32 random bytes, base64url (43
  characters); only their sha256 is stored (the nonce is stored as issued, it is not a secret). Idle and absolute
  expiry answer 401 `token_expired`; a session or member token that is unknown, revoked or for a frozen or departed
  member answers 401 `unauthenticated`. A mutation on a session without the right `X-CSRF-Token` is 403 `forbidden`.
- Bodies are JSON only (`Content-Type: application/json`, else 400 `invalid_request`) and at most 16 KB (413
  `too_large`). `POST /v1/devices/enroll` and `/challenge` take no `Idempotency-Key`: the code is single use and a
  nonce is meant to be fresh.
- Audit: `member.logged_in` (`{ method: "oidc" | "magic_link", session_id }`), `device.enrolled`
  (`{ key_storage, jwk_thumbprint }`), `device.revoked` (`{ via: "session" | "member_token" }`). Ids only.

### Devices (core)

Enrollment is loopback PKCE (S256). The Mac opens the browser at `/v1/devices/authorize`; the member is logged in by
session; the server stores a single-use code (10 min) in `device_enrollment_codes` and redirects to the loopback.

| Method and path | Request | Response |
|---|---|---|
| `GET /v1/devices/authorize?code_challenge=&code_challenge_method=S256&redirect_uri=&state=` | session required (without one, 302 to `/auth/login?return_to=` this URL); a code is issued only for a navigation with `Sec-Fetch-Site: none` (the Mac opening the browser) or `same-origin`, anything else gets a 200 HTML page (no framing) asking to confirm with a same-origin link; `redirect_uri` must be `http://127.0.0.1:<port>/callback` with port 1024..65535, else 400 `invalid_request` | 302 to `redirect_uri` with `code` and `state` |
| `POST /v1/devices/enroll` | `{ code, code_verifier, redirect_uri, public_jwk, name, key_storage }` (`redirect_uri` must equal the stored one) | `{ device_id }`; 400 `invalid_request` on an unknown, used or expired code, a wrong verifier, a key that is not a P-256 public JWK, or a redirect mismatch. No session: the code is the proof |
| `POST /v1/devices/challenge` | `{ device_id, audience: "device" \| "member" }` | `{ nonce, expires_at }` (2 min; the token gets this audience); 401 `unauthenticated` for an unknown or revoked device; 429 `rate_limited` (`Retry-After: 120`) when the device already holds 20 open nonces |
| `POST /v1/devices/token` | `{ device_id, nonce, signature }` | `{ token, expires_at }` (15 min); 401 `unauthenticated` for a bad signature or revoked device; 401 `token_expired` for an expired nonce; 409 `nonce_used` |
| `GET /v1/devices` · `DELETE /v1/devices/{id}` | session or member token; owner and admin see and revoke every device of the tenant, others their own | `Device[]` (`{ id, member_id, name, key_storage, enrolled_at, revoked_at }`) · 204, also for an already revoked device; 404 for another member's device. Revocation is immediate: tokens already minted fail on their next use |
| `GET /v1/devices/{id}/pseudonym-key-wrap` · `PUT /v1/devices/{id}/pseudonym-key-wrap` (M3, m3-01) | device token (`aud=device`, own device only); PUT body `{ wrapped_key, wrapped_by_device_id \| null, method: "device" \| "recovery_code", recovery_wrap? }` (`recovery_wrap` only from the first device) | GET: this device's `{ wrapped_key, wrapped_by_device_id, method }`, or `{ recovery_wrap }` for a new device with no wrap yet (`null` while the tenant has no recovery copy); another device's id is 404 · PUT: 204 (`recovery_wrap` is refused with 400 once another device holds it). Ciphertext only ([ADR 0028](adr/0028-stable-keyed-pseudonyms.md)) |
| `GET /v1/devices/pending-key-wraps` (M3, m3-06) | device token; lists enrolled devices of the tenant that still need the key | `{ devices: [{ device_id, public_jwk }] }` |

### Profile and privacy (core)

| Method and path | Request | Response |
|---|---|---|
| `GET /v1/profile` (M5) | | `Profile` |
| `PATCH /v1/profile` (M5) | partial `Profile`; goals ≤ 3, each ≤ 80 chars, one line; enums checked | `Profile` (400 `schema_invalid`) |
| `GET /v1/exclusions` · `POST` · `DELETE /v1/exclusions/{id}` (M3) | `{ kind, value }` | `Exclusion` |
| `POST /v1/imports` · `GET /v1/imports` (M3) | `{ source_kind }` | `{ import_id }` · `Import[]` |
| `GET /v1/me/export` (M7) | | 202 `{ export_id }`; then `GET /v1/me/export/{id}` → signed URL to JSON |
| `POST /v1/me/forget` (scope `import` M3; others M7) | `{ scope: "entity" \| "range" \| "all" \| "import", entity_id?, from?, to?, import_id? }` | 202 `{ purge_request_id }`; `GET /v1/purge-requests/{id}` → `{ state }` |
| `POST /v1/entities/{id}/confirm-name` (M7) | `{ name }` or `{ dont_track: true }` | `Entity` |
| `POST /v1/pseudonyms/candidates` (M5) | `{ opportunity_id, connection_id }` (Mac UI) | `{ candidates: [{ ref, value }] }` (C6 values from the connector, to the member's own device only) |
| `POST /v1/pseudonyms/matches` (M5) | `{ opportunity_id, matches: [{ pseudonym: "h_…", candidate_ref }] }` (the Mac hashes candidates locally) | 204 |
| `POST /v1/learning/pause` · `/resume` (M5) | | `Profile` |

### Today, records and review (core; M5 unless noted)

| Method and path | Response |
|---|---|
| `GET /v1/today?date=` | `{ day_grid: { categories[], cells[], switch_bursts[] }, what_you_did[], repeats[] (Figure each), suggested_fix: Opportunity \| null }`. The grid and bursts are computed from episodes at read time |
| `GET /v1/records/days/{date}` | `DayRecord` |
| `GET /v1/records/weeks/{iso_week}` | `WeekRecord` (404 for a future week) |
| `GET /v1/records/months/{month}` (M7) | `MonthRecord` |
| `GET /v1/records/quarters/{quarter}` (M7) | `QuarterRecord` |
| `GET /v1/review/week?w=` | `{ sentence, tiles[] (Figure), goals[], questions[] }` (404 for a future week) |
| `POST /v1/review/answers` | body `{ iso_week, subject_key, question_kind, answer, goal_id? }` → `ReviewAnswer` |
| `GET /v1/facts?entity_id=&at=` (M7) | `Fact[]` valid at `at`, each with `valid_at`, `invalid_at` |
| `GET /v1/figures/{figure_id}/evidence` | `{ arithmetic, evidence[], source_purged_at }` |

User model shapes (handlers in `services/brain/src/http/handlers.ts`, slices p43a and p43b; zod contracts follow in
`packages/contracts`):
- `Profile`: `{ version, role, industry, goals: [{ id, text, horizon: "90d", created_at, archived_at: null }], drains[],
  schedule: { days[], start, end } | null, timezone, review_slot: { day, time }, autonomy, own_name_to_models,
  keyframes_to_cloud, learning_paused, updated_at }`. Days are `mon` … `sun`; times `HH:MM`; `timezone` is IANA. A
  profile never saved answers the defaults (`version` 0, review slot `fri` `16:00`, autonomy `suggest`).
- `PATCH /v1/profile` accepts only `role`, `industry`, `goals`, `drains`, `schedule`, `timezone`, `review_slot`,
  `autonomy`, `own_name_to_models`, `keyframes_to_cloud`; any other field (including `version`, `updated_at`,
  `learning_paused`) is 400 `schema_invalid`. `goals` is a list of strings (or `{ text }`), at most 3, each one line of
  at most 80 characters with no `<`, `>`, email address or link. The same text (case-insensitive) keeps its goal id; a
  goal left out is archived. Goal, role and industry text may not hold a control or invisible format character (a tab,
  NEL, a zero-width space, a line separator; so emoji joined with a zero-width joiner are refused too) nor a link, including a bare `www.` or any host
  name (`acme.com`, `bit.ly`, `shop.example`), an IP address, or a full-width dot. Code file names are allowed: a
  dotted word ending in a code or document suffix (`md`, `js`, `ts`, `py`, `sh`, `rs`, `json`, `pdf` and the like, for
  example `README.md` or `Node.js`), so a host on one of those suffixes (`bun.sh`) is accepted too. The weekly
  sentence written by a model has no such exception. A body that is not JSON, or not sent as `application/json`, is
  400 `invalid_request`; a body over
  64 KiB is 413 `too_large`. The same body rules apply to `POST /v1/review/answers`.
- `DayRecord`, `WeekRecord`, `MonthRecord` and `QuarterRecord` carry every number as a `Figure`. A malformed date,
  week, month or quarter is 400 `invalid_request`; no record (or a future week in the member's timezone) is 404.
- `POST /v1/review/answers`: `question_kind` is `opportunity` in v1 (name and outcome questions come in M7);
  `subject_key` is a task key; `answer` is one of `keep`, `not_now`, `build`, `never`, `leave_alone`, `other_goal`;
  `goal_id` goes with `keep`, `build` or `other_goal` and is required with `other_goal`. A bad shape is 400
  `schema_invalid`; an unknown goal or a future week is 400 `invalid_request`. 200 returns the stored `ReviewAnswer`
  `{ iso_week, subject_key, question_kind, answer, goal_id, answered_at }` (latest wins per week and subject).

### Opportunities, fixes and builds (core)

| Method and path | Request | Response |
|---|---|---|
| `POST /v1/opportunities` | `{ title, description, workspace_id? }` (typed by the user; masked and leak scanned before storage) | 201 `Opportunity` with `source: "manual"`, state `open` ([ADR 0036](adr/0036-opportunity-sources-and-instant-read.md)) |
| `POST /v1/connections/{id}/instant-read` (M5) | | 202; opportunities with `source: "instant_read"` follow |
| `GET /v1/opportunities?state=open` | | `Opportunity[]` with `source`, `factors` (Figures) and `options[]` |
| `GET /v1/opportunities/{id}` | | `Opportunity` (includes `missing_connections[]` in `needs_connection`) |
| `POST /v1/opportunities/{id}/answer` | `{ answer: "build" \| "not_now" \| "never" \| "leave_alone", option_id? }` | `Opportunity` (state `chosen`, then `needs_connection`, `capturing_fixtures`, `designing` for build kinds) |
| `GET /v1/fixes/{id}` | | `Fix` with `brief`, `brief_hash`, `check_set_hash`, `held_out_hash`, `fixture_set_hash`, `estimate`, `cap_usd` |
| `POST /v1/fixes/{id}/build-approvals` (**OK, build**) | `{ brief_hash, check_set_hash, held_out_hash, fixture_set_hash, cap_usd: 4.00 }` | 202 `{ build_id }`; 400 `invalid_request`; 403 `hash_mismatch` (any hash, or `cap_usd` not the build cap); 403 `policy_denied`; 404 `not_found`; 409 `already_running` when a build of this brief is queued or running (the second of two concurrent requests gets this; a live build with no progress for longer than the stale limit is ended `infra_failed` instead); 409 `state_conflict` when the held-out check was already used by any build of this brief (a new one is written first, [ADR 0029](adr/0029-build-verdicts.md)) |
| `GET /v1/builds/{id}` | | `Build` with `state`, `spent_usd`, `cap_usd`, `fanout_workers`, `stages[]` (`name`, `state`, `started_at`, `ended_at`, `note` in plain words), `attempts[]` (with `check_groups[]`, `artifact_sha256`, `artifact_bytes`, `artifact_files[]`), `winner_attempt_id`, `artifact_sha256`, `receipt_hash`, `definition_hash`, `deployed`, `started_at`, `ended_at` |
| `GET /v1/builds/{id}/events` | | SSE: `build.stage`, `build.check_result`, `build.attempt_finished`, `build.spend`, `build.finished` |
| `POST /v1/builds/{id}/cancel` | | `Build` |
| `POST /v1/builds/{id}/retry` | | 202 `{ build_id }` for `infra_failed` builds whose approval was released ([ADR 0031](adr/0031-build-infrastructure-failures.md)); else 409 `state_conflict` |
| `GET /v1/builds/{id}/definition` | | `{ definition, definition_hash, words[] }`: trigger, each step's capability, which account (provider + account label), limits, in words ([ADR 0032](adr/0032-deploy-approval-binds-definition.md)) |
| `POST /v1/builds/{id}/deploy` (**deploy approval**) | `{ artifact_sha256, receipt_hash, definition_hash }` | 201 `{ routine_id, version }`; 403 `hash_mismatch`; 409 `state_conflict` unless `ready`, and for a build already deployed (once only, also when two arrive at once; a deploy that fails before the routine exists can be retried) |
| `GET /v1/builds/{id}/receipt` | | `{ receipt, receipt_hash, signature, key_id }` |

The approval token is internal: the server mints it when it accepts `build-approvals` (or `deploy`, batch approve,
graduation), stores only `sha256(token)`, and the workflow claims it atomically. Clients never see it. A workflow that
finds the approval already claimed gets `approval_used` (internal; surfaced on the build as `failed` only if it ever
happens); an approval past 24 h is `409 approval_expired`.

### Routines, runs and batches (core)

| Method and path | Request | Response |
|---|---|---|
| `GET /v1/routines` · `GET /v1/routines/{id}` | | `Routine` (with `state`, `commit_mode`, `clean_run_streak`, `graduation_proposal: { approval_id, clean_run_streak } \| null`, open `breaker_trips[]`) |
| `POST /v1/routines/{id}/pause` · `/resume` · `/retire` | | `Routine` |
| `POST /v1/routines/{id}/repair` (M6) | `{ reason? }` | 202 `{ fix_id }`: a new brief revision from the same brief plus failure evidence; fixtures re-captured, held-out regenerated; needs OK, build and deploy again; new version starts in `ask_before_commit` with streak 0 |
| `PATCH /v1/routines/{id}/policy` (M6) | `{ quiet_hours?: { start, end } \| null, max_items_per_run?, max_runs_per_day? }` (limits can only go down without a new deploy) | `Routine` |
| `POST /v1/routines/{id}/graduation` (M6) | `{ decision: "accept" \| "decline", approval_id }` | `Routine` |
| `POST /v1/routines/{id}/run` | | 202 `{ run_id }` (manual trigger) |
| `GET /v1/routines/{id}/runs` · `GET /v1/runs/{id}` | | `Run` |
| `GET /v1/batches/{batch_hash}` | | `Batch` with items (real values restored, visible to approvers only) |
| `POST /v1/batches/{batch_hash}/approve` | `{ item_hashes?: [] }` (subset allowed) | `Batch`; 403 `hash_mismatch` |
| `POST /v1/batches/{batch_hash}/reject` | `{ reason? }` | `Batch` |
| `POST /v1/items/{id}/release` | | `Item` (only from `unknown`; sets `released_by`) |
| `POST /v1/kill-switches` · `DELETE /v1/kill-switches/{id}` | `{ scope, scope_id }` | `KillSwitch` |

Routine artifacts follow `routine.json` ([ADR 0026](adr/0026-routine-artifact-contract.md)). Browser-automation commits
always ask, in every commit mode and every plan.

#### Routine artifact contract (`packages/routine-sdk`)

`routine.json` is `RoutineDefinition` (zod in `packages/routine-sdk/src/routine.ts`, exported to JSON Schema 2020-12
as `packages/routine-sdk/schemas/routine.schema.json`; the resolved form is `resolved-routine.schema.json`). Every
object is closed (`additionalProperties: false`).

| Field | Rule |
|---|---|
| `v`, `name` | `1`; 1 to 80 characters |
| `trigger` | `{ kind: "schedule", cron (5 fields, numeric), timezone? (IANA) }` · `{ kind: "webhook" }` · `{ kind: "event", event_type }` · `{ kind: "manual" }` |
| `steps[].id` | `^[a-z][a-z0-9_]{0,31}$`, unique |
| `steps[]` by `class` | `read`, `draft`, `commit`: `capability` and `connection_ref` required. `transform`: `transform` (`transforms/<name>.ts`), no capability. `model`: `model: { route, prompt_ref (prompts/*.md), output_schema_ref (schemas/*.json) }`, no capability, connection or tools |
| `steps[].runs_on` | `cloud`, or `device` only for a `commit` step whose capability is `shortcut.run`, `appleevent.template`, `ax.action` or `browser.step` |
| `steps[].foreach` | an earlier step id |
| `steps[].args` | object whose leaves are template strings (below) |
| `limits` | `max_items_per_run` 1..500, `max_runs_per_day` 1..96, `run_budget_usd` > 0 and ≤ 4.00, `quiet_hours?: { start, end } \| null` (`HH:MM`), `recipients_from?` (a step id) |
| `capabilities` | unique; must list every step's capability |

Cross-step rules (unique ids, earlier-step references, listed capabilities, cron ranges, IANA zone) are zod
refinements: validate with `parseRoutine`, not with the JSON Schema alone.

**Templates.** A template string is text plus references, nothing else: `{{ steps.<id>.output<json pointer> }}`
(an earlier step's output, narrowed by an optional RFC 6901 pointer, for example
`{{ steps.payouts.output/data/0/amount }}`) and `{{ item.<field> }}` (inside `foreach` only). `{{` and `}}` appear only
as reference delimiters; expressions such as `{{ 1 + 1 }}` are rejected. `renderArgs(template, scope)` is pure: a string
that is exactly one reference becomes the referenced JSON value; a reference inside text must be a string, number or
boolean. Only own properties and array indexes resolve.

**Commit items.** `planCommit(step, scope)` returns `Item = { item_key, item_hash, capability, connection_ref, args }`,
one per `foreach` element (or one item). `item_hash = sha256Hex(JCS({ capability, connection_ref, args }))`;
`item_key = "<step id>/" + sha256Hex(JCS(foreach element))` (of the rendered args without `foreach`), so the same input
keeps its key across runs. The SDK performs no I/O.

**Definition.** `resolveDefinition(def, pins)` adds to each `read`, `draft` and `commit` step the pinned
`connection_id`, `adapter`, `provider`, `account_label`, `tool_name` and `tool_pin_hash`
([ADR 0033](adr/0033-pinned-connector-resolution-and-launch-catalog.md)); a missing connection or tool pin is an error.
`definition_hash = sha256Hex(JCS(resolved))` ([ADR 0032](adr/0032-deploy-approval-binds-definition.md)).
`describeDefinition(resolved)` returns the `words[]` of `GET /v1/builds/{id}/definition`, for example
`Step payouts: reads payouts.list (stripe · acme-live).` and `At most 50 items a run and 1 run a day. Run budget $0.50.`

**Deploy checks.** `checkManifest(def, brief)` fails with `capability_not_in_brief` unless
`def.capabilities ⊆ brief.capabilities`, and with `connection_not_in_brief` unless every `connection_ref` is pinned in
the brief. `loadTransform(source)` checks that a transform loads in the isolate.

**Transforms.** `runTransform(source, input)` runs a compiled transform module (`export default function (input)`) in a
QuickJS isolate (`quickjs-emscripten`) with no host functions: no `fetch`, timers, `require`, module imports or console;
64 MiB memory and 1 s time. Input and output are JSON values. Errors carry `code`: `transform_timeout`,
`transform_memory`, `transform_error` (the transform threw) or `transform_invalid` (does not load, or input or output
is not JSON).

**Fake connector** (`packages/testkit`, tests only). `fakeConnector(fixtureSet)` replays recorded reads keyed by
`(capability, sha256Hex(JCS(args)))`, records commit items without executing them, and fails on a read it has no
recording for (`no_recording`, and `assertNoMissedReads()` after the run). Fixture strings must be fixture tokens
(`tok_` + 12 hex), ISO dates or listed enum values ([ADR 0027](adr/0027-fixture-capture-and-connector-content.md)).

### Connections (core)

Resolution is pinned at design time: the brief names `connection_id`, adapter, tool name and tool pin hash per step,
and the runtime never re-resolves ([ADR 0033](adr/0033-pinned-connector-resolution-and-launch-catalog.md)).

| Method and path | Request | Response |
|---|---|---|
| `GET /v1/connections` | | `Connection[]` (no secrets; with `account_label`, `state`) |
| `POST /v1/connections` | `{ adapter, provider, workspace_id, personal: bool }` | `{ connection_id, authorize_url? }` |
| `GET /v1/connections/{id}/tools` | | `{ tools: [{ name, pin_hash }] }` |
| `DELETE /v1/connections/{id}` | | 204 (credential crypto-shredded by the broker) |
| `GET /v1/capabilities` | | `Capability[]` with argument schemas and step class |
| `GET /v1/catalog` | | launch catalog: per app the method (`google_internal`, `composio`, `mcp`, `openapi`) |

### Metrics, audit and policy

| Method and path | Plan | Response |
|---|---|---|
| `GET /v1/metrics/hours-saved?scope=&period=` | core (M4) | `HoursSavedReport` (hs-1, floor of 5 for groups) |
| `GET /v1/outcomes?month=` | core (M4) | `FixOutcome[]` (`pending`, `on_track`, `partial`, `under`, `unmeasured`, with arithmetic) |
| `GET /v1/audit-events?cursor=` | core | `AuditEvent[]` |
| `GET /v1/audit-events/verify` | core | `{ ok, checked, first_bad_seq? }` |
| `POST /v1/audit-exports` · `GET /v1/audit-exports/{id}` | **ee** (M9) | `{ export_id, url }` |
| `PUT /v1/audit-streams/{id}` | **ee** (M9) | SIEM sink config (`audit_streams`) |
| `PUT /v1/anchor-sinks/{id}` | **ee** (M9) | external anchor sink config (`anchor_sinks`) |
| `GET /v1/policies` | core | built-in rules (TypeScript, with `rule_id`) and custom policies (read) |
| `PUT /v1/policies/{id}` · `POST /v1/policies/simulate` | **ee** (M9) | `Policy` (Cedar) · `{ decisions[] }` over past runs |
| `GET /v1/notices` · `POST /v1/feature-enablements` | **ee** (M9) | team monitoring notices and enablement records ([OQ-15](OPEN_QUESTIONS.md#oq-15-monitoring-law-features-for-teams)) |
| `GET /v1/budget?scope=` | core | spend by scope from `budget_entries` and `model_usage` |

`service_principals` and `circuit_breaker_trips` writes are internal; trips are read through `GET /v1/routines/{id}`.

## 3. Device ingest

[ADR 0020](adr/0020-device-ingest-protocol.md). Core. Lands in M3; `step_result` objects are accepted from M6.

| Method and path | Body | Response |
|---|---|---|
| `POST /v1/ingest/batches` | `IngestEnvelope` (JCS bytes) | `IngestReceipt` |
| `POST /v1/ingest/keyframes` (M5) | `multipart/form-data`: `meta` (JSON `KeyframeMeta`, signed) + `image` (JPEG ≤ 512 KiB) | `IngestReceipt`; 403 `consent_missing` unless `keyframes_to_cloud` (always until M5) |
| `GET /v1/ingest/config` | device token | `{ flush_seconds: 300, max_objects: 500, max_bytes: 1048576, exclusions[], keyframes_to_cloud }` (`exclusions[]` is `{ kind, value, source }`: the built-in list then the member's own rows; `keyframes_to_cloud` is `false` until M5) |

```json
{
  "v": 1,
  "device_id": "0193a6f2-6c1e-7b51-9d2a-5f0e8c1b2a33",
  "seq": 1842,
  "sent_at": "2026-11-14T16:05:00-05:00",
  "kind": "observation_batch",
  "objects": [
    { "id": "01JC...", "ts": "2026-11-14T16:01:12-05:00", "kind": "focus",
      "app_bundle_id": "com.google.Chrome", "app_name": "Google Chrome", "title": "Finance 2026 - Google Sheets",
      "host": "docs.google.com", "doc": "<doc:h_7c1e09b2a4d35f6e>" },
    { "id": "01JC...", "ts": "2026-11-14T16:02:30-05:00", "kind": "text_snapshot", "text_source": "ax", "app_bundle_id": "com.apple.mail",
      "text": "Reply to <person:h_0123456789abcdef> about the invoice", "text_hash": "9f2c..." }
  ]
}
```

Headers: `Authorization: Bearer <device token>` (aud `device`), `Offload-Signature: keyid=<device_id>, sig=<base64url>`.

**Upload kinds** (closed set; `envelope.kind` selects the object schema): `observation_batch`, `review_event`,
`notice_ack`, `keyframe`, `step_result`. `keyframe` envelopes on `/batches` are `400 unknown_kind` (keyframes come only
through `/v1/ingest/keyframes`). Every object of a kind not yet enabled is rejected `not_enabled`: `review_event` until
M4, `step_result` until M6, `notice_ack` until M9. `observation_batch` objects are rejected `consent_missing` until the
device's member has a current, not withdrawn upload consent (`POST /v1/me/consents`); the Mac does not send them
before that, so this is a server-side backstop.

**Object schemas** (all `additionalProperties: false`, `id` is a ULID, `ts` RFC 3339):

| Schema | Fields |
|---|---|
| `Observation` | `id`, `ts`, `kind`, `app_bundle_id?`, `app_name?`, `title?` (masked, ≤ 512), `host?` (no scheme, no path), `doc?` (`<doc:h_…>`), `keys?`, `clicks?` (int 0..100000), `text?` (≤ 8000 chars), `text_hash?` (`sha256Hex(text)`, 64 lowercase hex), `text_source?` (`ax`, `ocr`), `reason?` (`user`, `lock`, `sleep`, `permission`), `perm?` (`{ screen_recording: bool, accessibility: bool }`), `source?` (`live`, `import`), `import_id?` (uuid) |
| `ReviewEvent` | `id`, `ts`, `run_id` (uuid), `review_seconds`, `edit_seconds`, `fix_seconds`, `items_edited` (all int ≥ 0), `decision` (`approved`, `approved_with_edits`, `rejected`, `partial`, `policy_committed`), `surface: "mac"` |
| `NoticeAck` | `id`, `ts`, `notice_id` (uuid), `notice_version` (string) |
| `KeyframeMeta` | `id`, `ts`, `phash` (16 hex), `width` (≤ 1280), `height`, `bytes` (≤ 524288), `sha256` |
| `StepResult` | `id`, `ts`, `command_id` (uuid), `item_hash`, `outcome` (`sent`, `failed_before_send`, `unknown`), `detail_code?`, `finished_at` |

**Where the shapes live.** `packages/contracts/src` (zod) is the source; `packages/contracts/schemas/*.schema.json`
(Draft 2020-12, `$id` `https://offload.consultance.ai/schemas/<name>.json`, regenerated with
`bun packages/contracts/scripts/gen-json-schema.ts`, a test fails if stale) is what Swift generates from. The envelope's
`objects` hold 1 to 500 items. `Observation` is one strict shape per `kind` (a field not listed for its kind is
`schema_invalid`). Id fields: object `id` is a ULID, `run_id`, `command_id`, `notice_id`, `import_id` and `device_id`
are uuids; `phash` and `sha256` are lowercase hex. `host` is a bare host name (letters, digits, hyphens, dots). Receipt
ids are plain strings of 1 to 64 characters, because an object whose own `id` was malformed is still named in the
receipt. A `Figure` carries its `id` and the validator checks it equals `fig_` + 16 hex of `sha256Hex(jcs(rest))`.
The JSON Schema states the shape, the bounds, the per-kind rules and `import_id` for imports. These rules are checked by zod only,
so every consumer repeats them (the Mac egress guard, [ADR 0035](adr/0035-mac-egress-guard-and-ledger.md)):
`text_hash = sha256Hex(text)`; `title`, `text`, `app_name` and `app_bundle_id` hold no `<kind:...>` token (any `<...:...>`
after NFKC normalisation) other than a pseudonym or a router placeholder (`<person:[a-z]{4}\.[0-9]+(\.first)?>`,
`<person:[a-z]{4}\.me>`); the `Figure` id check. `notice_version` and `detail_code` are codes (`[A-Za-z0-9_.-]`). Length limits count
UTF-16 code units in zod and code points in JSON Schema.

Required `Observation` fields per `kind`:

| `kind` | Required besides `id`, `ts`, `kind` |
|---|---|
| `focus` | `app_bundle_id`, `app_name` |
| `idle_start`, `idle_end` | none |
| `input_counts` | `keys`, `clicks` |
| `text_snapshot` | `app_bundle_id`, `text`, `text_hash`, `text_source` |
| `pause`, `resume` | `reason` |
| `permission_change` | `perm` |

**Processing order** (each step's failure short-circuits; nothing is stored for a whole-request failure):
1. Device token valid, audience `device` (401 `unauthenticated` / `token_expired`). Rate limit 60/min (429).
2. Body ≤ 1 MiB (413 `too_large`); body equals its JCS (400 `invalid_request`); signature verifies (401
   `unauthenticated`).
3. `envelope.device_id` and `keyid` equal the token's `device_id` claim, else `403 forbidden`.
4. Look up `ingest_batches (device_id, seq)`: same `body_sha256` → return the stored receipt; different bytes →
   `409 seq_replay`. Otherwise `seq` must be greater than `devices.last_seq`, else `409 seq_replay`.
5. `sent_at` within ±10 minutes of server time, else `400 clock_skew` for the whole batch.
6. Envelope schema; unknown `kind` → `400 unknown_kind`.
7. Per object: schema (`schema_invalid`; `ts` more than 10 minutes in the future is `schema_invalid`); `too_old` when
   `ts` is older than now − 7 days (imported objects excepted: they carry `source = "import"` and the `import_id`
   of an open import, and their `day` is the ingest date, [ADR 0020](adr/0020-device-ingest-protocol.md)); kind enabled (`not_enabled`); upload consent for `observation_batch`
   (`consent_missing`); leak scan (`leak_detected`, audit
   `privacy.leak_blocked` with object id and detector name only); exclusion (`excluded`: `host`, `app_bundle_id` or
   `title` matches a member exclusion).
8. In one transaction: insert accepted objects `ON CONFLICT DO NOTHING` (`observations` and `observation_texts` key
   `(tenant_id, device_id, object_id, day)`; `review_events` and `notice_acks` key `(tenant_id, device_id,
   object_id)`), insert `ingest_batches` with `body_sha256` and the receipt, update `devices.last_seq`, write
   `observations.ingested` to `events_outbox`.
9. Return the receipt.

`IngestReceipt`: `{ "accepted": ["01JC..."], "rejected": [{ "id": "01JC...", "code": "leak_detected" }] }`.
A batch whose objects were all rejected is still a processed batch: its receipt is stored and its `seq` is used, so a resend of the
same bytes returns the same receipt. Only a whole-request failure (steps 1 to 6) leaves `seq` free. `observations.ingested` is written only
when at least one object was accepted. The rate limit is a per-process sliding window of 60 requests per minute per device; `429` carries
`Retry-After`. Retention: the daily `retentionPurge` workflow (03:15 UTC) drops `observations` and `observation_texts` partitions older
than `OFFLOAD_RAW_TTL_DAYS` and `OFFLOAD_TEXT_TTL_DAYS` and writes `purge_log` (`raw_ttl`, `text_ttl`) for each tenant that lost rows.
Object rejection codes: `schema_invalid`, `leak_detected`, `excluded`, `too_old`, `unknown_kind`, `not_enabled`,
`consent_missing`, `rate_limited` (retryable), `server_error` (retryable).

The server leak scan is a transport check with the same rules as the device: email, Luhn card, IBAN, API-key patterns,
URL with a path or query, phone. Pseudonyms (`<person:h_…>`, `<doc:h_…>`) pass. Names are not scanned server-side
([ADR 0035](adr/0035-mac-egress-guard-and-ledger.md)).

## 4. Device commands

[ADR 0025](adr/0025-execution-placement-and-mac-actuator.md). Core. M6. Device steps are commit-class: the runtime
queues an approved item for the member's device; the Mac re-checks the item hash, runs the typed command, and posts a
`StepResult` through ingest.

| Method and path | Request | Response |
|---|---|---|
| `GET /v1/device/commands?wait=30` | device token (`aud=device`); long poll up to 30 s | `{ commands: [{ id, command, payload, item_hash, expires_at }] }`; returned commands move to `claimed` |
| `POST /v1/device/commands/{id}/decline` | `{ reason }` (the person stopped an attended step, or the hash did not match) | 204; item becomes `failed_before_send` |

Commands (typed, no command takes model-written script text): `shortcut.run { name, input? }`,
`appleevent.template { template, params }`, `ax.action { app, path, action, value? }`,
`browser.step { profile, action, selector, value? }` (attended). Device offline → run state `awaiting_device`; a command
not claimed in 24 h is `expired` and its item `failed_before_send`; claimed without a result in 10 min → item
`unknown`.

## 5. Offload MCP server

Core. M8. Streamable HTTP at `/mcp`, auth by personal access token with scope `mcp`. Read and propose only; no tool
commits anything outside Offload ([ADR 0010](adr/0010-mcp-first-connectors.md)).

| Tool | Input | Output |
|---|---|---|
| `offload.get_today` | `{ date? }` | Today payload (Figures) |
| `offload.get_week_record` | `{ iso_week }` | `WeekRecord` |
| `offload.list_opportunities` | `{ state? }` | `Opportunity[]` |
| `offload.search_episodes` | `{ query, from?, to?, limit? }` | `Episode[]` (masked) |
| `offload.list_routines` | `{}` | `Routine[]` |
| `offload.get_build` | `{ build_id }` | `Build` |
| `offload.propose_opportunity` | `{ title, description, task_key? }` | `Opportunity` in state `open` with `source: "agent"`; title and description are masked and leak scanned at the edge; ranked like any other |

Tool results are masked text. Inputs are untrusted and validated against the schema.

## 6. Webhooks

**Inbound** (core, M6): `POST /v1/hooks/{trigger_id}`. Header `Offload-Webhook-Signature: t=<unix>, v1=<hex
HMAC-SHA256 of "t.body">` with the trigger's secret. Accepted when `|now − t| ≤ 300 s` (a 300-second-old timestamp is
accepted, 301 is rejected). Bad signature or skew → `401 unauthenticated`, no run starts. Body ≤ 256 KiB, treated as
untrusted input to the routine. Response `202 { run_id }`.

**Outbound** (core, M8): tenants register endpoints for event types. Same signature scheme with the endpoint secret.
Retries with exponential backoff for 24 hours, tracked in `outbox_deliveries`. Payload = the internal event envelope
below, ids only.

| Method and path | Request | Response |
|---|---|---|
| `GET /v1/webhook-endpoints` · `POST` · `DELETE /v1/webhook-endpoints/{id}` | `{ url, event_types[] }` | `{ id, secret }` (secret shown once) |

## 7. Internal events

Written to `events_outbox` in the same transaction as the change; delivered to durable workflows and outbound webhooks
(one `outbox_deliveries` row per consumer). Payloads carry ids and hashes, never content.

```json
{ "id": "0193a6f2-...", "type": "build.ready", "version": 1, "tenant_id": "...", "at": "2026-11-14T16:40:00Z",
  "subject": { "kind": "build", "id": "..." }, "data": { } }
```

| Type | Emitted by | Data |
|---|---|---|
| `observations.ingested` | api (ingest) | `{ device_id, member_id, seq, accepted }` (as m3-01 writes it; optional `first_ts`, `last_ts` narrow the range understanding reads). Consumer `workflow:understanding` (m5-01) |
| `day.closed` | brain | `{ member_id, day }` |
| `records.updated` | brain | `{ member_id, kind: "day" \| "week" \| "month" \| "quarter", key }` |
| `opportunity.ranked` | brain | `{ member_id, iso_week, opportunity_ids[] }` |
| `opportunity.chosen` | api | `{ opportunity_id, fix_id }` |
| `opportunity.needs_connection` | brain | `{ opportunity_id, providers[] }` |
| `fixtures.captured` | brain | `{ fix_id, fixture_set_id, count }` |
| `fix.ready_for_approval` | brain | `{ fix_id, brief_hash, check_set_hash, held_out_hash, fixture_set_hash }` |
| `build.approved` | api | `{ build_id, approval_id }` |
| `build.attempt_finished` | builder | `{ build_id, attempt_id, ordinal, outcome }` |
| `build.ready` · `build.failed` · `build.capped` · `build.tampered` · `build.infra_failed` | builder | `{ build_id, spent_usd }` |
| `routine.deployed` | api | `{ routine_id, version, artifact_sha256, definition_hash }` |
| `routine.needs_review` | runtime | `{ routine_id, reason }` |
| `run.batch_ready` | runtime | `{ run_id, batch_hash, item_count }` |
| `run.awaiting_device` | runtime | `{ run_id, device_id, command_ids[] }` |
| `run.finished` | runtime | `{ run_id, state }` |
| `saving.measured` | runtime | `{ run_id, saved_seconds, grade }` |
| `policy.graduation_proposed` | runtime | `{ routine_id, clean_run_streak, approval_id }` |
| `breaker.tripped` | runtime | `{ routine_id, reason }` |

## 8. Core and EE summary

| Surface | Core | EE |
|---|---|---|
| Auth (one OIDC provider, magic link), me, devices, pseudonym key wraps, profile, privacy, imports, today, records, review, facts, opportunities (manual, instant read), fixes, builds, routines, batches, device commands, connections, catalog, metrics, outcomes, audit read and verify, policies read, budget, ingest, support grants | yes | |
| Offload MCP server, outbound webhooks (M8) | yes | |
| Team tenants: workspaces create, invites (M8, decided, [OQ-13](OPEN_QUESTIONS.md#oq-13-plan-contents-and-prices)) | | yes |
| SCIM, SSO config, audit exports and streams, anchor sinks, custom policy write and simulate, notices and feature enablements (M9) | | yes |
