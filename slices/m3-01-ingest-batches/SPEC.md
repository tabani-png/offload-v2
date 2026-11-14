---
id: m3-01-ingest-batches
title: POST /v1/ingest/batches with signature, seq, clock and device checks, schema validation, upload consent, transport leak scan, idempotent insert, outbox event, pseudonym key wraps, and the scheduled retention purge
milestone: M3
status: ready
depends_on: [m1-02-contracts-ingest, m1-03-tenancy-rls, m1-04-login-devices]
parallel_safe: true
human_gated: false
model_tier: sonnet
size: L
parallel_group: M3-A
owns: [services/api/src/ingest/**, packages/masking/**]
verify: bash slices/m3-01-ingest-batches/verify.sh
min_tests: 34
paths_in_scope: [services/api/**, packages/masking/**, packages/db/**, packages/testkit/**, slices/m3-01-ingest-batches/**, docs/API.md, package.json, bun.lock]
paths_out_of_scope: [ee/**, apps/**, services/brain/**, services/builder/**, services/runtime/**, services/broker/**, packages/contracts/src/**, docs/adr/**]
red_tests: [INGEST, LEAK, TTL, OUTBOX, KEYWRAP, CONSENT]
---

# m3-01-ingest-batches

## Summary
The ingest module of the API process for [M3](../../docs/ROADMAP.md#m3-capture-to-cloud)
([ARCHITECTURE section 3](../../docs/ARCHITECTURE.md#3-ingest), [ADR 0020](../../docs/adr/0020-device-ingest-protocol.md)).
First version of `packages/masking` as a server-side **transport check** with a fixed detector list
([SECURITY_PRIVACY.md section 5](../../docs/SECURITY_PRIVACY.md#5-masking),
[ADR 0035](../../docs/adr/0035-mac-egress-guard-and-ledger.md)). The scheduled `retentionPurge` workflow on the
durable runtime from m1-01. The pseudonym key wrap routes from [ADR 0028](../../docs/adr/0028-stable-keyed-pseudonyms.md).
Runs in parallel with the M2 loop. It owns `services/api/src/ingest/**` and `packages/masking/**`; M2 tasks that touch
`services/api`, `packages/db` or `packages/testkit` stay out of those folders, add their own migration files and
rebase before landing ([AGENTS.md](../../AGENTS.md#slice-format)).

## Contract
- Delete `packages/masking/tests/smoke.test.ts` (the TODO marker is replaced).
- No new dependencies (hono, jose, pg are pinned already).
- Routes (device token, audience `device`):
  - `POST /v1/ingest/batches`, body = `IngestEnvelope` JCS bytes, header `Offload-Signature: keyid=<device_id>,
    sig=<base64url raw r‖s>`.
  - `POST /v1/ingest/keyframes` → 403 `consent_missing` in this slice (opt-in arrives in M5).
  - `GET /v1/ingest/config` → `{ flush_seconds: 300, max_objects: 500, max_bytes: 1048576, exclusions[],
    keyframes_to_cloud: false }` (`false` until M5).
  - `PUT /v1/devices/{id}/pseudonym-key-wrap { wrapped_key, wrapped_by_device_id | null, method: "device" |
    "recovery_code", recovery_wrap? }` (`recovery_wrap`, the scrypt-wrapped copy, only from the first device) and
    `GET /v1/devices/{id}/pseudonym-key-wrap` (only the device's own wrap; a device with no wrap yet gets
    `{ recovery_wrap }`). The server stores
    ciphertext only (`pseudonym_key_wraps`); it never sees the key.
- **Order of checks** (stop at the first failure; the same order as [API.md section 3](../../docs/API.md#3-device-ingest)):
  1. device token (ES256, `aud = device`) → `tenant_id`, `member_id`, `device_id`, else 401; then the rate limit, 60
     requests per minute per device, else 429 `rate_limited` with `Retry-After`;
  2. body over 1 MiB → 413 `too_large`; body must equal `jcs(JSON.parse(body))`, else 400 `invalid_request`; signature
     over the exact body bytes with the device's public JWK, else 401 `unauthenticated`;
  3. `envelope.device_id` and `keyid` must equal the token's `device_id`, else 403 `forbidden`;
  4. look up `ingest_batches (tenant_id, device_id, seq)`: same `body_sha256` → return the stored receipt (200);
     different bytes → 409 `seq_replay`; not found → require `seq > devices.last_seq`, else 409 `seq_replay`;
  5. `sent_at` within ±10 minutes of server time, else 400 `clock_skew` for the whole batch, nothing stored;
  6. per envelope kind: `observation_batch` continues; `review_event`, `notice_ack`, `step_result` → every object
     rejected `not_enabled` (until M4, M9 and M6); `keyframe` on this route → 400 `unknown_kind` (keyframes only via
     `/v1/ingest/keyframes`); unknown kind → 400 `unknown_kind`;
  7. per object: schema (`schema_invalid`); `ts` older than now − 7 days → `too_old`; `ts` later than now + 10 min →
     `schema_invalid`; no current upload consent for the member (`consents` row for the current notice version, not
     withdrawn) → `consent_missing`; leak scan → `leak_detected`; exclusion match → `excluded`;
  8. in one `withTenant` transaction: insert accepted objects (`observations`, or `observation_texts` for
     `text_snapshot`, `ON CONFLICT (tenant_id, device_id, object_id, day) DO NOTHING`), `ingest_batches` row with
     `body_sha256` and receipt, `devices.last_seq = seq`, `events_outbox` `observations.ingested`, audit
     `privacy.leak_blocked` per leak (object id and detector name only);
  9. return `IngestReceipt`.
- **Upload consent**: migration for `consents` ([DATA_MODEL.md section 3](../../docs/DATA_MODEL.md#3-tenancy-and-identity));
  routes `POST /v1/me/consents` and `DELETE /v1/me/consents/what-leaves-your-mac` (member token), and the
  `upload_consent` field of `GET /v1/me`, exactly as in [API.md](../../docs/API.md#auth-and-me-core). The current notice
  version comes from `packages/db/src/config.ts` (`UPLOAD_NOTICE_VERSION`).
- **Leak scan (transport check)**, `packages/masking/src/detectors.ts`, rules ported from the old Swift `Detectors/*`
  and old `brain/src/playbook/leak.ts`, rewritten: email address; card number passing Luhn (13 to 19 digits); IBAN with
  valid checksum; API-key and token patterns (`sk-ant-`, `sk-`, `gh[pousr]_`, `github_pat_`, `AKIA`/`ASIA` + 16,
  `xox[abpr]-`, JWT three-part base64url, PEM header, `Bearer `); URL with a path, query or fragment; phone number
  (E.164 or 10+ digits with separators). Names are **not** scanned server-side (the device pseudonymises them). Text
  matching a pseudonym or router placeholder is skipped before scanning.
- **Exclusions**: `packages/masking/src/exclusions.builtin.json` (shared with the Mac; same file is copied into the Mac
  bundle by m3-02) plus the member's `exclusions` rows. Match rules: `host` exact or dot-suffix (`bank.example` matches
  `www.bank.example`), `bundle_id` exact, `title_contains` case-insensitive substring.
- **Retention**: `retentionPurge`, a durable scheduled workflow (daily 03:15 UTC) run as `offload_retention`, reading
  `packages/db/src/config.ts`: drops `observations` partitions older than `OFFLOAD_RAW_TTL_DAYS` and
  `observation_texts` partitions older than `OFFLOAD_TEXT_TTL_DAYS`; writes `purge_log` (`scope = 'raw_ttl'` and `'text_ttl'`) per tenant. Keyframes are not stored in this slice.

## Red tests
Folder: `services/api/tests/m3-01-ingest-batches/`.

| Tag | Test name | Asserts |
|---|---|---|
| INGEST | INGEST: a valid batch is stored and every id is accepted | |
| INGEST | INGEST: same batch twice stores objects once and returns the same receipt | |
| INGEST | INGEST: identical resend after restart returns the stored receipt | new process, same bytes and seq |
| INGEST | INGEST: same seq with different bytes is 409 seq_replay | |
| INGEST | INGEST: a seq not above last_seq is 409 seq_replay | |
| INGEST | INGEST: sent_at off by 11 minutes is 400 clock_skew and nothing is stored | |
| INGEST | INGEST: a bad signature is 401 and nothing is stored | |
| INGEST | INGEST: a DER signature or a non-JCS body is rejected | |
| INGEST | INGEST: envelope device_id different from the token's device is 403 | a token for tenant A cannot write into tenant B |
| INGEST | INGEST: kind run_outcome is rejected unknown_kind | |
| INGEST | INGEST: keyframe envelopes on /batches are 400 unknown_kind | |
| INGEST | INGEST: review_event, notice_ack and step_result objects are rejected not_enabled | |
| INGEST | INGEST: an object older than 7 days is too_old and one 11 minutes in the future is schema_invalid | |
| INGEST | INGEST: 1 MiB + 1 byte is 413 too_large | |
| INGEST | INGEST: the 61st request in a minute is 429 rate_limited | |
| INGEST | INGEST: an excluded host is rejected excluded | dot-suffix match from the builtin list |
| INGEST | INGEST: keyframe upload is 403 consent_missing | |
| INGEST | INGEST: text snapshots land in observation_texts and other kinds in observations | |
| CONSENT | CONSENT: observations from a member without upload consent are rejected consent_missing | nothing stored |
| CONSENT | CONSENT: consent for the current notice version lets the next batch through and is audited | `privacy.consent_given` |
| CONSENT | CONSENT: a stale notice_version is 409 stale_notice and a withdrawn consent blocks uploads again | |
| CONSENT | CONSENT: GET /v1/me reports upload_consent.needed until consent exists | |
| LEAK | LEAK: an email address in text is rejected leak_detected and audited | audit details hold object id and detector only |
| LEAK | LEAK: a card number passing Luhn is rejected | |
| LEAK | LEAK: an sk-ant style key is rejected | |
| LEAK | LEAK: a URL with a query string in title is rejected | |
| LEAK | LEAK: a valid IBAN and a phone number are rejected | |
| LEAK | LEAK: pseudonyms and router placeholders pass | `<person:h_0123456789abcdef>`, `<person:qkzt.1>` |
| OUTBOX | OUTBOX: observations.ingested is written in the same transaction | `onBeforeCommit` throws; neither row exists |
| TTL | TTL: observations older than the raw TTL are dropped by the purge job and logged | fake clock |
| TTL | TTL: text snapshots older than the text TTL are dropped while metadata stays | 8-day-old text gone, focus row kept |
| TTL | TTL: changing OFFLOAD_RAW_TTL_DAYS changes what is dropped | no hard-coded 30 |
| KEYWRAP | KEYWRAP: a device stores and reads back only its own wrapped key | |
| KEYWRAP | KEYWRAP: another device's wrap is 404 | |

## Out of scope
Understanding, records, keyframe storage (M5), the Mac uploader (m3-02), device command routes (M6).

## Verify
`bash slices/m3-01-ingest-batches/verify.sh` (needs `DATABASE_URL`).

## Scope changes
None.
