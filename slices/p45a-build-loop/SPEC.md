---
id: p45a-build-loop
title: Port of old PR #45 OK, build into the builder - hash-checked approval, frozen check set and held-out check, teeth gate, one test-first worker, parallel check shards in fresh Docker sandboxes with the container guard, fan-out on check failure, build cap, build lock
milestone: M2
status: done
depends_on: []
parallel_safe: true
human_gated: false
model_tier: opus
size: L
parallel_group: M2-C
owns: [services/builder/**]
verify: bash slices/p45a-build-loop/verify.sh
min_tests: 75
paths_in_scope: [services/builder/**, packages/hours-saved/src/measured/**, packages/hours-saved/tests/p45b-measured-saving/**, packages/hours-saved/src/index.ts, slices/p45a-build-loop/**, slices/p45b-measured-saving/**, NOTICE, docs/API.md, docs/DATA_MODEL.md, docs/MIGRATION.md]
paths_out_of_scope: [ee/**, apps/**, .github/**, docs/adr/**, packages/db/**, packages/contracts/**, packages/policy/**, packages/routine-sdk/**, packages/connectors-sdk/**, packages/testkit/**, services/api/**, services/runtime/**, services/broker/**, services/brain/**, package.json, bun.lock]
red_tests: [GATE, CHECKS, HELDOUT, TEETH, DEFAULT1, SHARDS, FANOUT, STALL, LOCK, SHIP, BUDGET, CAP, TAMPER, PROOF, VERDICT, SANDBOX, INFRA, DEPLOY, READY, TDD, STEPS, ERROR, API, RLS]
---

# p45a-build-loop

## Summary
Ports old PR #45 (`feat/build-loop`, s35 "OK, build", both commits `f075da0` and `473cafb`) into `services/builder`,
as [MIGRATION section 5.6](../../docs/MIGRATION.md#56-pr-45-featbuild-loop-s35-ok-build) plans. It moves the
[M2](../../docs/ROADMAP.md#m2-hand-fed-loop) build half (m2-07, m2-08 builder parts) and the M6 fan-out of 3 forward,
behind ports for the parts other streams own. Implements [ARCHITECTURE section 8](../../docs/ARCHITECTURE.md#8-build-orchestrator)
and [section 9](../../docs/ARCHITECTURE.md#9-sandboxed-tdd-workers), [ADR 0011](../../docs/adr/0011-sandboxed-build-workers.md),
[ADR 0012](../../docs/adr/0012-builder-policy-one-worker-held-out-fan-out.md), [ADR 0029](../../docs/adr/0029-build-verdicts.md),
the build cap and reservations of [ADR 0030](../../docs/adr/0030-build-budget-at-egress-proxy.md) and `infra_failed`
from [ADR 0031](../../docs/adr/0031-build-infrastructure-failures.md). The old code review, the file mapping and every
hole found are in [DESIGN.md](DESIGN.md). No hard `depends_on`: approvals (m2-06), the model router (W1-F), the durable
runtime (W1-C), the fix designer (m2-05), the Agent SDK worker (m2-07) and the runtime (m2-09) are local ports with
stubs, listed in DESIGN.md section 4.

## Contract
- Delete `services/builder/tests/smoke.test.ts` (the TODO marker is replaced).
- No new dependency. Postgres through Bun's built-in `SQL`. Docker through its CLI (injected executor).
- Config (`src/config.ts`, overridable, never in queries): build cap `4.0000`, checks reserve `0.3000`, attempt cap
  `0.7000`, `fanout_workers` 1 (allowed 1 to 3), tries per attempt 2, worker wall 12 min, verification 5 min,
  `STALE_AFTER_MS` = 2 × (worker wall + verification). Money is integer ten-thousandths of a USD.
- `POST /v1/fixes/{id}/build-approvals` `{ brief_hash, check_set_hash, held_out_hash, fixture_set_hash, cap_usd }` →
  202 `{ build_id }`; 400 `invalid_request`; 403 `hash_mismatch` (any hash or `cap_usd` not equal); 404 `not_found`;
  409 `already_running`; 409 `state_conflict` when the held-out hash was already used by a build of this brief.
- `GET /v1/builds/{id}` → `Build` `{ id, state, cap_usd, spent_usd, fanout_workers, stages[], attempts[] (with
  check_groups[]), winner_attempt_id, artifact_sha256, receipt_hash, definition_hash, started_at, ended_at }`.
- `POST /v1/builds/{id}/deploy` `{ artifact_sha256, receipt_hash, definition_hash }` → 201 `{ routine_id, version }`;
  403 `hash_mismatch`; 409 `state_conflict` unless `ready` and not yet deployed.
- Handlers are web-standard `(Request, { tenant_id, member_id }) → Response` (`src/http.ts`); `services/api` mounts them.
- Tables (`services/builder/sql/0001_builder.sql`, adopted by `packages/db` later): `builds` (DATA_MODEL fields plus
  `bound_hashes`, `created_at`, `heartbeat_at`, `deployed_at`; partial unique index = the build lock),
  `worker_attempts`, `budget_reservations`, `budget_entries` (append-only, unique idempotency key), `build_receipts`
  (unsigned until m2-07). Each with forced tenant RLS.
- Ports: `SandboxProvider` (Docker provider; cloud provider stub), `ApprovalPort`, `ModelPort`, `DurableRuntime`,
  `FixStore`, `WorkerPort`, `RoutinePort`, `BuildStore` (memory and Postgres).

## Red tests (write these first, run them, see them fail)
Tests live in `services/builder/tests/p45a-build-loop/`. Old s35 names are re-stated for v2; the carried and dropped
list is in DESIGN.md. Postgres tests create and drop their own schema and role per file.

| Tag | Covers | Old source |
|---|---|---|
| GATE | exact-hash, single-use, 24 h approvals; wrong hash 403 with nothing stored or run; the build claims first; each attempt its own claim; concurrent OKs | loop, surfaces, routes-hardening; ROADMAP M2 GATE; SECURITY 13 |
| CHECKS | check reply rules (TypeScript only, imports), checks read by hash, held-out never reaches a builder | loop, checks |
| HELDOUT | separate `check_write` call, brief + interface only, copies refused, never in BUILD.md, runs only in verification, used hash refused | heldout, runner-options; ROADMAP M2 HELDOUT |
| TEETH | a check passing on an empty workspace, or writing into it, stops the build before any worker | loop, loop-hardening, runner-options; SECURITY 13 |
| DEFAULT1, SHARDS, FANOUT | one worker; shards in parallel fresh sandboxes, any fail = FAIL; fan-out only on FAIL; winner order; own claims; no orphans; container guard with real planted files | loop, loop-hardening, container, container-guard; ROADMAP M2/M6 FANOUT |
| STALL, TAMPER, PROOF, VERDICT | stalled attempts; changed check ends `tampered`; exit 0 without nonce proof fails; worker-printed pass does not count | runner-options; ROADMAP M2; SECURITY 13 |
| LOCK | 409 while live; stale build recovered; stale limit; Postgres race | loop, loop-hardening, routes-hardening |
| BUDGET, CAP | $4.00 cap, $0.30 reserve, $0.70 attempts, fewer workers on a small cap, refused before spending; parallel reservations cannot overshoot | loop, loop-hardening; ROADMAP M2 CAP; SECURITY 13 |
| SANDBOX | exact Docker argv, no credentials, no network allowlist, timeouts removed, temps removed; `LIVE:` real Docker | container; SECURITY 13 |
| INFRA | provider outage → `infra_failed`, nothing billed, approval released once | ROADMAP M2 INFRA |
| DEPLOY, SHIP | wrong hash 403, not ready 409, deploying twice 409 | routes-hardening, surfaces; ROADMAP M2 DEPLOY |
| READY, TDD, STEPS, ERROR, API | ready shape, no paths or tokens stored, TDD instructions, stages in plain words, errors end the build, HTTP shapes | loop, loop-hardening, surfaces |
| RLS | another tenant's builds are invisible to `offload_app`-like roles | DATA_MODEL section 1 |

## Out of scope
Verifier and repair turn, replay fixtures, receipt signing, model egress proxy, reaper, E2B provider, artifact object
storage and the artifact capability scan (m2-07, m2-08). The approvals table and the `packages/policy` scheme (m2-06).
Check writing and the design budget (m2-05). Routine versions (m2-09). The `LOCAL` tier (m5-03).
ADR 0031's retry path (m2-08): `POST /v1/builds/{id}/retry`, the automatic retries (3 within an hour) and
`builds.infra_retries` (stored, never written here). This slice only releases the approval once on a no-spend
`infra_failed` build, for that endpoint to claim. Pinning the sandbox image by digest (spike S4, m2-08).

## Verify
`bash slices/p45a-build-loop/verify.sh`: typecheck; the slice suite has at least `min_tests` tests and every tag is
present and passing; the full suite passes; every change since `BASE` matches `paths_in_scope` and none matches
`paths_out_of_scope`. Needs Postgres 17 at `DATABASE_URL`.

## Scope changes
- `paths_in_scope` is shared with `p45b-measured-saving` (one port, two slices), so re-verifying either done slice
  does not trip on the other's files.
- DATA_MODEL `builds` gains `fix_id`, `bound_hashes`, `artifact_sha256`, `receipt_hash`, `definition_hash`,
  `created_at`, `heartbeat_at`, `deployed_at` and the build-lock index; `worker_attempts` gains `artifact_sha256`,
  `artifact_bytes`, `artifact_files`, `note`. The docs had no place for the lock's staleness, for "deployed once", or
  for the hashes a held-out regeneration is checked against.
- Held-out reuse follows ADR 0029 as written: a held-out hash is used as soon as any build of the brief is bound to
  it, so every new build (also after stale recovery, a failed mint or a teeth failure) needs a fresh held-out check.
  `insertQueued` checks it in the lock's transaction, after the live-build check, so a running build still answers
  `already_running`. (Green commit `724dbd3` had loosened this to "used once a worker started"; review round 2
  restored the red assertion.) API.md and DATA_MODEL.md say so.
- Review gate (an independent Opus security review) findings fixed: attempts beat the heartbeat before each try and
  before their shards; a build ended by stale recovery refuses every later write (`BuildEnded`) and its orchestrator
  stops; the attempt row exists before the worker starts; a failed approval mint ends the queued build; claims bind
  `kind` and `subject_id`; a deploy that fails before the routine exists clears `deployed_at`. Open items are in
  DESIGN.md section 7.
- API.md: the OK, build and deploy rows list the codes this slice returns (400, 404, 409 `state_conflict`).
- MIGRATION 5.6: `models/local.ts` is handed to m5-03 (the router owns it), and the port is linked.
