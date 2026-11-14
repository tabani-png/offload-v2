---
id: m1-01-contracts-ingest
title: Ingest contracts in packages/contracts (zod → JSON Schema 2020-12), RFC 8785 JCS, hashes, error envelope
milestone: M1
status: ready
depends_on: []
parallel_safe: true
human_gated: false
verify: bash slices/m1-01-contracts-ingest/verify.sh
min_tests: 14
paths_in_scope: [packages/contracts/**, slices/m1-01-contracts-ingest/**, docs/API.md, package.json, bun.lock]
paths_out_of_scope: [ee/**, apps/**, services/**, packages/db/**, docs/adr/**]
red_tests: [CONTRACT, JCS, KIND]
---

# m1-01-contracts-ingest

## Summary
First contracts for M1 ([ROADMAP M1](../../docs/ROADMAP.md#m1-capture-to-cloud)): the device ingest envelope, the four
upload kinds, the observation object, the receipt, the error envelope, the `Figure` type, the JCS canonicaliser and
sha256 helpers. Implements [ADR 0008](../../docs/adr/0008-contracts-first.md) and the shapes in
[API.md section 3](../../docs/API.md#3-device-ingest). Adds `zod` (exact pin) as the first dependency of
`packages/contracts`.

## Contract
- `IngestEnvelope { v: 1, device_id, seq (int ≥ 0), sent_at (RFC 3339), kind, objects[] }`; `objects.length` 1..500.
- `UploadKind = "observation_batch" | "review_event" | "notice_ack" | "keyframe"` (closed).
- `Observation { id (ULID), ts, kind: "focus"|"idle_start"|"idle_end"|"input_counts"|"text_snapshot"|"pause"|"resume", app_bundle_id?, app_name?, title?, host?, keys?, clicks?, text? (≤ 8000 chars), text_hash?, source?: "live"|"import", import_id? }`,
  `additionalProperties: false`. `host` has no path, no scheme.
- `ReviewEvent`, `NoticeAck`, `KeyframeMeta` as in [DATA_MODEL.md](../../docs/DATA_MODEL.md#5-capture) and
  [section 7](../../docs/DATA_MODEL.md#7-routines-and-runs).
- `IngestReceipt { accepted: string[], rejected: { id, code }[] }`; rejection codes from API.md section 3.
- `ErrorEnvelope { error: { code, message, request_id } }`; `Figure { value, unit, arithmetic, evidence[], source_purged_at }`.
- `jcs(value): string` (RFC 8785), `sha256Hex(bytes|string): string`.
- Generator `bun packages/contracts/scripts/gen-json-schema.ts` writes `packages/contracts/schemas/*.schema.json`
  (Draft 2020-12, `$id` `https://offload.consultance.ai/schemas/<name>.json`). Committed. A test fails if they are stale.

## Red tests (write first, run, see them fail)
Folder: `packages/contracts/tests/m1-01-contracts-ingest/`.

| Tag | Test name | Asserts |
|---|---|---|
| CONTRACT | CONTRACT: observation_batch round-trips zod ↔ JSON Schema 2020-12 | a valid fixture passes both validators; an invalid one fails both |
| CONTRACT | CONTRACT: unknown fields on an observation are rejected | `additionalProperties: false` holds in zod and JSON Schema |
| CONTRACT | CONTRACT: text over 8000 characters is rejected | |
| CONTRACT | CONTRACT: host with a path or scheme is rejected | `"example.com/a"` and `"https://example.com"` fail |
| CONTRACT | CONTRACT: objects array of 501 is rejected | |
| CONTRACT | CONTRACT: generated JSON Schemas are fresh | regenerating produces byte-identical files |
| CONTRACT | CONTRACT: every schema declares Draft 2020-12 | `$schema` is `https://json-schema.org/draft/2020-12/schema` |
| CONTRACT | CONTRACT: Figure requires arithmetic and evidence | |
| CONTRACT | CONTRACT: error envelope codes are the closed list in API.md | |
| JCS | JCS: canonical bytes match RFC 8785 test vectors | numbers, unicode escapes, key order |
| JCS | JCS: object key order does not change the hash | |
| JCS | JCS: sha256Hex of a known string matches a fixed vector | |
| KIND | KIND: the four upload kinds are accepted | |
| KIND | KIND: run_outcome, baseline_sample and daily_aggregate are rejected | old kinds are gone ([ADR 0020](../../docs/adr/0020-device-ingest-protocol.md)) |

## Out of scope
Database tables, HTTP routes, Swift type generation (M1 follow-up inside m1-05), any service code.

## Verify
`bash slices/m1-01-contracts-ingest/verify.sh`.

## Scope changes
None.
