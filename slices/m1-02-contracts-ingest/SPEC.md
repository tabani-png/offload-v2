---
id: m1-02-contracts-ingest
title: Ingest contracts in packages/contracts (zod to JSON Schema 2020-12) - envelope, five upload kinds, pseudonym shape, RFC 8785 JCS, hashes, error envelope, Figure
milestone: M1
status: done
depends_on: []
parallel_safe: false
human_gated: false
model_tier: sonnet
size: M
parallel_group: M1-B
owns: [packages/contracts/**, docs/API.md]
verify: bash slices/m1-02-contracts-ingest/verify.sh
min_tests: 22
paths_in_scope: [packages/contracts/**, slices/m1-02-contracts-ingest/**, docs/API.md, package.json, bun.lock, NOTICE, .github/workflows/ci.yml, scripts/check-workflows.ts, scripts/tests/workflows.test.ts, scripts/lib/slice-changes.sh, scripts/tests/slice-changes.test.ts]
paths_out_of_scope: [ee/**, apps/**, services/**, packages/db/**, docs/adr/**]
red_tests: [CONTRACT, JCS, KIND, PSEUDO]
---

# m1-02-contracts-ingest

## Summary
First contracts for [M1](../../docs/ROADMAP.md#m1-foundations): the device ingest envelope, the five upload kinds, every
device object schema, the pseudonym shape, the receipt, the error envelope, the `Figure` type, the JCS canonicaliser and
sha256 helpers. Implements [ADR 0008](../../docs/adr/0008-contracts-first.md), the shapes in
[API.md section 3](../../docs/API.md#3-device-ingest), the pseudonym shape from
[ADR 0028](../../docs/adr/0028-stable-keyed-pseudonyms.md) and the upload kinds from
[ADR 0020](../../docs/adr/0020-device-ingest-protocol.md). Swift types are generated later from these schemas (m3-02).
Runs after m1-01: the durable spike goes before any other M1 slice
([ADR 0009](../../docs/adr/0009-durable-execution-on-postgres.md)).

## Contract
- Delete `packages/contracts/tests/smoke.test.ts` (the TODO marker is replaced).
- Dependencies (exact pins in `packages/contracts/package.json`): `zod` (exact 4.x), `@noble/hashes` (sync sha256 that
  runs in the browser; no Bun or WebCrypto APIs in this package, ADR 0002). Dev dependency: `ajv` (used as
  `ajv/dist/2020` for the round-trip tests only).
- Ids: `device_id` is a uuid everywhere. Object `id` is a ULID (26 chars Crockford base32). `run_id`, `command_id`,
  `notice_id` are uuids.
- `IngestEnvelope { v: 1, device_id: uuid, seq: int ≥ 0, sent_at: RFC 3339 with offset, kind: UploadKind, objects[] }`;
  `objects.length` 1..500; `additionalProperties: false`. `envelope.kind` selects the object schema.
- `UploadKind = "observation_batch" | "review_event" | "notice_ack" | "keyframe" | "step_result"` (closed).
- `Observation` (`additionalProperties: false`): `{ id, ts, kind, app_bundle_id?, app_name?, title?, host?, doc?, keys?,
  clicks?, text?, text_hash?, text_source?, reason?, perm?, source?: "live" | "import", import_id? }` with the per-kind
  rule (fields not listed for a kind are rejected):

  | kind | required | optional |
  |---|---|---|
  | `focus` | `app_bundle_id`, `app_name` | `title` (≤ 512), `host` (no scheme, no path, no port), `doc` (one pseudonym of kind `doc`) |
  | `idle_start`, `idle_end` | none | |
  | `input_counts` | `keys`, `clicks` (int 0..100000 per minute) | |
  | `text_snapshot` | `text` (≤ 8000 chars), `text_hash` (= `sha256Hex(text)`, 64 lowercase hex), `text_source` (`ax`, `ocr`), `app_bundle_id` | |
  | `pause`, `resume` | `reason` (`user`, `lock`, `sleep`, `permission`) | |
  | `permission_change` | `perm` `{ screen_recording: bool, accessibility: bool }` | |

  Every kind also allows `source` and `import_id` (uuid, the `imports` row id, required when `source = "import"`).
- `ReviewEvent { id, ts, run_id, review_seconds int ≥ 0, edit_seconds int ≥ 0, fix_seconds int ≥ 0, items_edited int ≥ 0,
  decision: "approved" | "approved_with_edits" | "rejected" | "partial" | "policy_committed", surface: "mac" }`.
- `NoticeAck { id, ts, notice_id, notice_version: string ≤ 32 }`.
- `KeyframeMeta { id, ts, phash: 16 hex, width int 1..1280, height int ≥ 1, bytes int 1..524288, sha256: 64 hex }`.
- `StepResult { id, ts, command_id, item_hash: 64 hex, outcome: "sent" | "failed_before_send" | "unknown",
  detail_code?: string ≤ 64, finished_at }`.
- **Pseudonym**: regex `<(person|email|phone|doc):h_[0-9a-f]{16}>`. `title` and `text` may contain pseudonyms and the
  router's per-run placeholders (`<person:[a-z]{4}\.[0-9]+(\.first)?>`, `<person:[a-z]{4}\.me>`). Any other `<kind:...>`
  token shape is rejected (`schema_invalid`). Export `PSEUDONYM_RE`, `isPseudonym`.
- `IngestReceipt { accepted: string[], rejected: { id, code }[] }`. Object rejection codes (closed): `schema_invalid`,
  `leak_detected`, `excluded`, `too_old`, `unknown_kind`, `consent_missing`, `not_enabled`, `rate_limited`
  (retryable), `server_error` (retryable).
- `ErrorEnvelope { error: { code, message, request_id, rule_id? } }`; `request_id` = `req_` + ULID. Codes (closed, as
  in [API.md](../../docs/API.md#error-envelope)): 400 `invalid_request`, `unknown_kind`, `schema_invalid`, `clock_skew`;
  401 `unauthenticated`, `token_expired`; 403 `forbidden`, `policy_denied` (with `rule_id`), `feature_not_licensed`,
  `hash_mismatch`, `consent_missing`; 404 `not_found`; 409 `already_running`, `approval_used`, `approval_expired`,
  `idempotency_conflict`, `seq_replay`, `nonce_used`, `last_owner`, `state_conflict`; 413 `too_large`; 422
  `leak_detected`, `teeth_gate_failed`, `budget_exceeded`, `recipient_not_allowed`; 429 `rate_limited`; 500
  `server_error`.
- `Figure { id, value, unit, arithmetic, evidence[], source_purged_at }`: `source_purged_at` is required and nullable;
  `id` = `fig_` + first 16 hex of `sha256Hex(jcs(figure without id))`.
- `jcs(value): string` (RFC 8785), `sha256Hex(bytes | string): string`.
- Generator `bun packages/contracts/scripts/gen-json-schema.ts` writes `packages/contracts/schemas/*.schema.json`
  (Draft 2020-12, `$id` `https://offload.consultance.ai/schemas/<name>.json`). Committed. A test fails if stale.
- JCS vectors: the input/output pairs from the `testdata` folder of cyberphone/json-canonicalization (Apache-2.0),
  copied to `packages/contracts/tests/fixtures/jcs/` (`*.input.json`, `*.output.json`) with the license header in a
  `README` there. The Swift JCS in m3-02 reads the same folder.

## Red tests (write first, run, see them fail)
Folder: `packages/contracts/tests/m1-02-contracts-ingest/`.

| Tag | Test name | Asserts |
|---|---|---|
| CONTRACT | CONTRACT: observation_batch round-trips zod ↔ JSON Schema 2020-12 | a valid fixture passes both validators; an invalid one fails both |
| CONTRACT | CONTRACT: unknown fields on an observation are rejected | `additionalProperties: false` holds in zod and JSON Schema |
| CONTRACT | CONTRACT: each observation kind enforces its required and allowed fields | the table above, one case per kind |
| CONTRACT | CONTRACT: text over 8000 characters is rejected | |
| CONTRACT | CONTRACT: text_hash must equal sha256Hex(text) | |
| CONTRACT | CONTRACT: host with a path, port or scheme is rejected | `example.com/a`, `example.com:8080`, `https://example.com` fail |
| CONTRACT | CONTRACT: objects array of 501 is rejected | |
| CONTRACT | CONTRACT: ReviewEvent, NoticeAck, KeyframeMeta and StepResult validate their fixtures | one valid and one invalid each |
| CONTRACT | CONTRACT: generated JSON Schemas are fresh | regenerating produces byte-identical files |
| CONTRACT | CONTRACT: every schema declares Draft 2020-12 | `$schema` is `https://json-schema.org/draft/2020-12/schema` |
| CONTRACT | CONTRACT: Figure requires arithmetic, evidence and a nullable source_purged_at | |
| CONTRACT | CONTRACT: Figure id is fig_ plus 16 hex of the JCS hash | |
| CONTRACT | CONTRACT: error envelope codes are the closed list in API.md | includes `clock_skew`, `nonce_used`, `recipient_not_allowed`; `rule_id` optional |
| CONTRACT | CONTRACT: receipt rejection codes are the closed list including not_enabled | |
| JCS | JCS: canonical bytes match RFC 8785 test vectors | every pair in `tests/fixtures/jcs/` |
| JCS | JCS: object key order does not change the hash | |
| JCS | JCS: sha256Hex of a known string matches a fixed vector | `sha256Hex("abc")` = `ba7816bf…15ad` |
| KIND | KIND: the five upload kinds are accepted | |
| KIND | KIND: run_outcome, baseline_sample and daily_aggregate are rejected | old kinds are gone ([ADR 0020](../../docs/adr/0020-device-ingest-protocol.md)) |
| PSEUDO | PSEUDO: the four pseudonym kinds with 16 hex are accepted | |
| PSEUDO | PSEUDO: a pseudonym with 15 hex, uppercase hex or an unknown kind is rejected | `<doc:h_ABC…>`, `<account:h_…>` fail |
| PSEUDO | PSEUDO: router placeholders are accepted and other angle tokens are rejected | `<person:qkzt.1.first>` passes; `<secret:x>` fails |

## Out of scope
Database tables, HTTP routes, Swift type generation (m3-02), REST contracts beyond ingest (added by the slices that
need them), any service code.

## Verify
`bash slices/m1-02-contracts-ingest/verify.sh`.

## Scope changes
- `NOTICE` added to `paths_in_scope`: AGENTS.md requires the Apache-2.0 JCS test vectors copied into
  `packages/contracts/tests/fixtures/jcs/` to be listed in `NOTICE` in the same commit.
- The error code list above omitted `stale_notice` (409); docs/API.md has it, and the test compares the code list to the
  API.md table, so the contract includes it (28 codes).
- Receipt `accepted` and `rejected[].id` are plain strings of 1 to 64 characters, not ULIDs, so an object with a
  malformed id can still be rejected by name.
- `import_id` is only required when `source = "import"` (as written); it is not rejected on other sources.
- zod-only rules (JSON Schema cannot express them): `text_hash` equality, the angle-token rule (`title`, `text`,
  `app_name`, `app_bundle_id`), the `Figure` id check. Listed in API.md section 3. `import_id` for imports is in both.
- Review fixes: wide token regex with NFKC, ULIDs start with 0-7, `notice_version` and `detail_code` are code strings, `jcs` rejects sparse arrays.
- CI harness fix added to `paths_in_scope` (`.github/workflows/ci.yml`, `scripts/check-workflows.ts`,
  `scripts/tests/workflows.test.ts`): this is the first `done` slice, and CI's shallow checkout has no `BASE` commit, so
  `check-slices.sh` failed with "BASE ... not found". The checkouts now use `fetch-depth: 0`, and the workflow linter
  fails any job that runs slice checks without it.
- CI scope fix added to `paths_in_scope` (`scripts/lib/slice-changes.sh`, `scripts/tests/slice-changes.test.ts`): on
  pull_request CI checks out GitHub's merge commit, so `BASE..HEAD` included files merged into `main` after `BASE`
  (PR #3) and the scope check failed. CI now sets `SLICE_UPSTREAM`, and only commits not already on it are checked.
