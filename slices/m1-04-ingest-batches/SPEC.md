---
id: m1-04-ingest-batches
title: POST /v1/ingest/batches with signature, seq and clock checks, schema validation, leak scan, idempotent insert, outbox event, and the raw-TTL purge job
milestone: M1
status: ready
depends_on: [m1-01-contracts-ingest, m1-02-tenancy-rls, m1-03-device-enrollment]
parallel_safe: false
human_gated: false
verify: bash slices/m1-04-ingest-batches/verify.sh
min_tests: 18
paths_in_scope: [services/api/**, packages/masking/**, packages/db/migrations/**, packages/testkit/**, slices/m1-04-ingest-batches/**, docs/API.md, package.json, bun.lock]
paths_out_of_scope: [ee/**, apps/**, services/brain/**, services/builder/**, services/runtime/**, docs/adr/**]
red_tests: [INGEST, LEAK, TTL, OUTBOX]
---

# m1-04-ingest-batches

## Summary
The ingest module of the API service ([ARCHITECTURE section 3](../../docs/ARCHITECTURE.md#3-ingest),
[ADR 0020](../../docs/adr/0020-device-ingest-protocol.md)). First version of `packages/masking` (server-side leak
scanner with the detector set in [SECURITY_PRIVACY.md section 5](../../docs/SECURITY_PRIVACY.md#5-masking)).
Raw-TTL purge job (default 30 days, constant `RAW_TTL_DAYS` read from config, never hard-coded in queries).

## Contract
- `POST /v1/ingest/batches` and `GET /v1/ingest/config` as in API.md section 3. Keyframes route returns
  `403 consent_missing` in this slice (opt-in arrives with the profile in M2).
- Order of checks: token → signature over JCS bytes → seq → sent_at (±10 min) → per-object schema → leak scan →
  exclusion match → insert `ON CONFLICT DO NOTHING` → `ingest_batches` row → `events_outbox` `observations.ingested`
  in the same transaction → receipt.
- A repeated batch (same device, same seq, same bytes) returns the stored receipt. Same seq with different bytes is
  `409 seq_replay`.
- Leak hits: object rejected `leak_detected`; audit row `privacy.leak_blocked` with object id and detector name only.
- Purge job: drops `observations` partitions older than `RAW_TTL_DAYS`, writes `purge_log` (`scope = 'raw_ttl'`).

## Red tests
Folder: `services/api/tests/m1-04-ingest-batches/`.

| Tag | Test name | Asserts |
|---|---|---|
| INGEST | INGEST: a valid batch is stored and every id is accepted | |
| INGEST | INGEST: same batch twice stores objects once and returns the same receipt | |
| INGEST | INGEST: replayed seq with different bytes is 409 seq_replay | |
| INGEST | INGEST: sent_at off by 11 minutes is rejected | |
| INGEST | INGEST: a bad signature is 401 and nothing is stored | |
| INGEST | INGEST: kind run_outcome is rejected unknown_kind | |
| INGEST | INGEST: 1 MiB + 1 byte is 413 too_large | |
| INGEST | INGEST: a token for tenant A cannot write into tenant B | RLS + token claims |
| INGEST | INGEST: an excluded host is rejected excluded | server-side exclusion list |
| INGEST | INGEST: keyframe upload is 403 consent_missing | |
| LEAK | LEAK: an email address in text is rejected leak_detected and audited | |
| LEAK | LEAK: a card number passing Luhn is rejected | |
| LEAK | LEAK: an sk-ant style key is rejected | |
| LEAK | LEAK: a URL with a query string in title is rejected | |
| LEAK | LEAK: masked placeholders like <person:qkzt.1> pass | |
| OUTBOX | OUTBOX: observations.ingested is written in the same transaction | rollback leaves neither |
| TTL | TTL: observations older than the raw TTL are dropped by the purge job and logged | fake clock |
| TTL | TTL: changing RAW_TTL_DAYS changes what is dropped | no hard-coded 30 |

## Out of scope
Understanding, records, keyframe storage, the Mac uploader.

## Verify
`bash slices/m1-04-ingest-batches/verify.sh`.

## Scope changes
None.
