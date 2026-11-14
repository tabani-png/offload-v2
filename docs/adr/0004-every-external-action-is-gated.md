# 0004. Every external action is gated

Status: accepted, revised 2026-11-14 · Date: 2026-11-14 · Carries over old ADR 0006, 0015, 0105, 0106

## Context
Offload sends mail, appends rows and calls APIs for the user, in the cloud and, for some fix kinds, on his Mac. A wrong
send cannot be taken back.

## Decision
- Every call that changes something outside Offload is a **commit** step and goes through the **gate** in the runtime.
  `read` and `draft` steps never change anything outside Offload and are enforced read-only by capability. Gate modes
  are `read` (connector reads only, used by fixture capture and the instant read) and `live`.
- The gate allows a commit only when one of these holds:
  1. a **batch approval** bound to the exact `batch_hash` (sha256 of the RFC 8785 JCS of the items), and the
     canonical hash of the call's full arguments equals one approved item's hash, used once; or
  2. a **policy allow** from the policy engine ([ADR 0017](0017-policy-engine-cedar.md)) for a routine in `auto_commit`
     mode, which mints an approval with `approver_kind = 'policy'`.
- Device-executed commits ([ADR 0025](0025-execution-placement-and-mac-actuator.md)) pass the same gate with the same
  item hash. The Mac re-checks the hash before it runs the typed command. The journal stays on the server.
- The **item journal** row moves to `sending` before the call. Edges: `pending → sending`, `pending →
  failed_before_send` (gate denied, approval expired, device command expired), `sending → sent`, `sending →
  failed_before_send` (the connector proved nothing was sent), `sending → unknown` (timeout, crash, no device result).
  `unknown` counts as done for dedupe and is never retried automatically; a person may release it, which sets
  `released_by` and `released_at` and keeps the state `unknown`.
- All approvals (build, deploy, batch, graduation) use one scheme. The approval token is **internal**: 32 random bytes
  minted when the user approves exact hashes, only `sha256(token)` stored, claimed atomically and once by the workflow
  that does the work, TTL 24 hours. The client never sees or sends the token; it sends the hashes.
- Concurrency: a second OK, build for a brief while a build for it is `queued` or running returns `409 already_running`.
  A workflow that tries to claim an already claimed approval gets `approval_used` (internal; it surfaces only as a
  failed workflow). An approval may be released once, only after an `infra_failed` build with no model spend
  ([ADR 0031](0031-build-infrastructure-failures.md)), and then claimed once more.
- One canonicaliser for every hash: RFC 8785 JCS, implemented once in `packages/contracts`.
- Kill switches at tenant, workspace, member and routine scope stop all commits at once.
- Models never open a gate. Credentials are used only by the credential broker, which re-checks the approval and the
  item hash ([ADR 0034](0034-credential-broker-and-key-providers.md)).

## Consequences
- The old workflow token (stored in plain text, no TTL) and the old batch hash (plain `JSON.stringify`) are replaced.
  Old approvals do not carry over.
- Two approvals exist for a fix: OK, build and deploy ([ADR 0032](0032-deploy-approval-binds-definition.md)). After
  deploy, commits still ask by default ([ADR 0016](0016-no-dry-run.md)).

## Alternatives considered
- Trust a model-based "is this safe" check. Rejected: non-deterministic.
- Show the token to the client and have it send it back. Rejected: the hashes already bind the approval; a bearer
  token adds a secret to leak (review-a #55).

## Sources
Old ADR 0006, 0015, 0105, 0106, 0112-review-b, 0113-round-2; old `brain/src/workflows/{gate,batch}.ts`, `builder/approval.ts`;
PR #45 (concurrent OK race fixed).

## Revisions
- 2026-11-14: approval token is internal; concurrency codes defined (review-a #55); journal edges match the state
  diagram, `released` is not a state (review-a #51); device commits use the same gate (review-c P0-1); release after
  `infra_failed` (review-c P1(2)); gate modes `read` and `live` defined here (review-a #81).
