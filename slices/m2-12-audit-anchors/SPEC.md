---
id: m2-12-audit-anchors
title: Hourly signed audit anchors, chain verify that detects an edited event, a deleted event and a fork, and the audit read and verify routes
milestone: M2
status: in_progress
depends_on: [m1-01-durable-spike, m1-02-contracts-ingest, m1-03-tenancy-rls, m1-04-login-devices]
parallel_safe: false
human_gated: false
model_tier: sonnet
size: S
parallel_group: M2-A
owns: [packages/db/src/audit/**, services/api/src/audit/**, packages/contracts/src/audit/**, packages/testkit/src/audit/**]
verify: bash slices/m2-12-audit-anchors/verify.sh
min_tests: 14
paths_in_scope: [packages/db/src/audit/**, packages/db/src/index.ts, packages/db/tests/m2-12-audit-anchors/**, services/api/src/audit/**, services/api/src/app.ts, services/api/tests/m2-12-audit-anchors/**, packages/contracts/src/audit/**, packages/contracts/src/index.ts, packages/contracts/scripts/gen-json-schema.ts, packages/contracts/schemas/**, packages/testkit/src/audit/**, slices/m2-12-audit-anchors/**, docs/API.md, package.json, bun.lock]
paths_out_of_scope: [ee/**, apps/**, services/broker/**, services/brain/**, services/builder/**, services/runtime/**, services/api/src/ingest/**, services/api/src/connections/**, packages/db/migrations/**, packages/masking/**, packages/connectors-sdk/**, docs/adr/**]
red_tests: [AUDIT, ANCHOR, VERIFY]
---

# m2-12-audit-anchors

## Summary
Completes the audit log of [ADR 0018](../../docs/adr/0018-audit-log-hash-chain.md) for the
[M2 exit](../../docs/ROADMAP.md#m2-hand-fed-loop) ("the audit chain verifies"). m1-03 already writes the chain
(`appendAudit`) and creates `audit_anchors`; this slice adds the hourly signed anchor job, `verifyChain`, and the core
routes `GET /v1/audit-events` and `GET /v1/audit-events/verify` from
[API.md, Metrics, audit and policy](../../docs/API.md#metrics-audit-and-policy). It owns the ROADMAP M2 test
`AUDIT: verify detects an edited event, a deleted event and a fork` and the matching row of
[SECURITY_PRIVACY section 13](../../docs/SECURITY_PRIVACY.md#13-security-tests-that-must-exist).
[ARCHITECTURE section 13](../../docs/ARCHITECTURE.md#13-governance-and-audit) states what core anchors prove: they are
signed by a key Offload holds and stored in the same database, so they catch accidental damage and tampering by someone
without that key, not the operator. The external anchor sink is EE (M9) and out of scope.

**Parallel.** ROADMAP puts this task in group M2-A. It is `parallel_safe: false` because it writes the shared
registration files that m2-02 owns while m2-02 runs (`services/api/src/app.ts`, the contracts generator and
`packages/contracts/schemas/**`) and the barrels `packages/db/src/index.ts` and `packages/contracts/src/index.ts`. It
runs alone in M2-A, before or after m2-02 and m2-03. It is size S, so this costs little.

**Port.** [MIGRATION section 2.7](../../docs/MIGRATION.md#27-control-plane-control-stage-2--services-packages-ee):
old `control/src/audit/{anchor,verify-chain}.ts` and `anchor-job.ts` are **keep**, `routes.ts` is **rewrite**. These
come from old `main`, not from PRs #43 to #45, and need the relicensing default of
[OQ-12](../../docs/OPEN_QUESTIONS.md#oq-12-relicensing-code-from-the-old-repo) (as m1-03's chain writer did). Old
tests come with them only after operator item O14 confirms old test canaries are fake.

## Contract
- No new dependency. Ed25519 through `node:crypto`; `hono` from m1-04; the durable runtime from m1-01.
- No new migration: `audit_events` and `audit_anchors` (with `head_hash`, `signed_at`, `signature`, `key_id`,
  `sink_ref`) exist from m1-03 ([DATA_MODEL section 8](../../docs/DATA_MODEL.md#8-connectors-governance-measurement-privacy)).
- **Contracts** (`packages/contracts/src/audit/`, zod, JSON Schema exported, added to the barrel):
  `AuditEvent { seq, id, at, principal_id, action, subject_type, subject_id, rule_id | null, details, prev_hash, hash }`,
  `AuditVerifyResult { ok: boolean, checked: number, first_bad_seq?: number, reason?: "hash_mismatch" | "seq_gap" |
  "prev_hash_mismatch" | "anchor_mismatch" | "anchor_signature" }`. `reason` is additive to the API.md shape; this
  slice adds it to API.md.
- **Signer port** (`packages/db/src/audit/signer.ts`): `ServiceSigner { keyId, sign(bytes): Uint8Array, verify(bytes,
  sig, keyId): boolean }`. Production implementation `fileSigner(ref)` reads an Ed25519 PKCS#8 PEM from the path named
  by `OFFLOAD_SERVICE_SIGNING_KEY_REF` (a KMS-held key is a later slice). `keyId` = first 16 hex of sha256 of the raw
  public key. Tests use `packages/testkit/src/audit/fakeSigner()` (a fresh keypair per test). The private key is never
  logged or written to a row.
- **Anchor** (`packages/db/src/audit/anchor.ts`): `writeAnchor(tx, tenantId, signer, now)` reads the chain head (last
  `seq`, `hash`); if the newest anchor already has that `seq`, writes nothing and returns `null`; else inserts
  `audit_anchors (tenant_id, seq, head_hash, signed_at, signature, key_id, sink_ref = null)` with `signature =
  base64url(sign(jcs({ tenant_id, seq, head_hash, signed_at })))`. The insert happens in the same short transaction as
  the head read; no network I/O inside it.
- **Anchor job**: a durable scheduled workflow `auditAnchor` on cron `0 * * * *` (UTC). It lists tenants through
  `jobs_list_tenants()` (role `offload_jobs`) and, per tenant, runs `writeAnchor` inside `withTenant` as `offload_app`.
  Workflow input and step outputs hold ids only ([ADR 0009](../../docs/adr/0009-durable-execution-on-postgres.md)).
- **Verify** (`packages/db/src/audit/verify.ts`): `verifyChain(tx, tenantId, signer) → AuditVerifyResult`. Walks events
  in `seq` order from 1: `seq` must have no gap (`seq_gap`), `prev_hash` must equal the previous row's `hash` (64 zeros
  for seq 1) (`prev_hash_mismatch`), and `hash` must equal `sha256Hex(prev_hash || jcs(event_without_hash))`
  (`hash_mismatch`). Then every anchor: `head_hash` equals the event hash at its `seq` (`anchor_mismatch`) and the
  signature verifies for its `key_id` (`anchor_signature`). `first_bad_seq` is the lowest failing `seq`; `checked` is
  the number of events walked. A fork (two rows naming the same `prev_hash`, only possible with the constraint dropped)
  is reported as `prev_hash_mismatch` at the later row.
- **Routes** (mounted under `/v1` in the API composition root; session or member token; tenant roles `owner`,
  `admin`, `auditor` only, `member` is 403 `forbidden`):
  - `GET /v1/audit-events?cursor=&limit=` → `{ items: AuditEvent[], next_cursor }` (limit max 200, newest first).
  - `GET /v1/audit-events/verify` → `AuditVerifyResult`. A run is audited as `audit.verified` with `ok` and `checked`
    in details.
- Exports from `packages/db/src/index.ts`: `writeAnchor`, `verifyChain`, `ServiceSigner`, `fileSigner`.
- Tamper tests connect as `offload_migrator`, disable the append-only trigger (and drop `UNIQUE (tenant_id,
  prev_hash)` for the fork case) inside the test, and restore it after.

## Red tests (write these first, run them, see them fail)
Folders: `packages/db/tests/m2-12-audit-anchors/` and `services/api/tests/m2-12-audit-anchors/` (real Postgres 17).

| Tag | Test name | Asserts |
|---|---|---|
| AUDIT | AUDIT: verify detects an edited event, a deleted event and a fork | ROADMAP M2 test; `ok: false` with the right `first_bad_seq` and `reason` for each |
| AUDIT | AUDIT: an untouched chain of 50 events verifies with checked 50 | |
| AUDIT | AUDIT: an empty chain verifies with checked 0 | |
| ANCHOR | ANCHOR: writeAnchor signs the JCS of tenant_id, seq, head_hash and signed_at | signature verifies with the public key |
| ANCHOR | ANCHOR: no new anchor is written when the chain head has not moved | |
| ANCHOR | ANCHOR: the hourly job anchors every tenant once per hour in a fake clock | two tenants, two ticks |
| ANCHOR | ANCHOR: the anchor job's workflow input and step outputs hold ids only | |
| ANCHOR | ANCHOR: offload_app cannot update or delete an anchor | append-only trigger from m1-03 |
| ANCHOR | ANCHOR: the signing key never appears in a row or a log line | canary PEM |
| VERIFY | VERIFY: an anchor whose head_hash no longer matches its event fails verify | `anchor_mismatch` |
| VERIFY | VERIFY: an anchor with a bad signature fails verify | `anchor_signature` |
| VERIFY | VERIFY: GET /v1/audit-events/verify returns ok, checked and first_bad_seq | |
| VERIFY | VERIFY: a member role gets 403 and an auditor gets the result | |
| VERIFY | VERIFY: GET /v1/audit-events pages newest first with next_cursor and reads only its own tenant | |

## Out of scope
The EE external anchor sink, audit export and SIEM streaming (`ee/packages/audit-export`, M9, ROADMAP test
`ANCHOR: an anchor written to the external sink re-verifies the chain offline`); a KMS-held signing key; the retention
job's delete-from-the-oldest-end path; the in-app audit viewer (web, M8); new audit actions for other modules.

## Verify
`bash slices/m2-12-audit-anchors/verify.sh` (needs `DATABASE_URL`, Postgres 17).

## Scope changes
None.
