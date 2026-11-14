# 0004. Every external action is gated

Status: accepted · Date: 2026-11-14 · Carries over old ADR 0006, 0015, 0105, 0106

## Context
Offload sends mail, appends rows and calls APIs for the user. A wrong send cannot be taken back.

## Decision
- Every call that changes something outside Offload is a **commit** step and goes through the **gate** in the runtime.
  `read` and `draft` steps never change anything outside Offload and are enforced read-only by capability.
- The gate allows a commit only when one of these holds:
  1. a **batch approval**: a single-use token bound to the exact `batch_hash` (sha256 of the RFC 8785 JCS of the items),
     and the canonical hash of the call's full arguments equals one approved item's hash, used once; or
  2. a **policy allow** from the policy engine ([ADR 0017](0017-policy-engine-cedar.md)) for a routine in `auto_commit`
     mode, which mints a token with `approver_kind = 'policy'`.
- The **item journal** row moves to `sending` before the call and to `sent`, `failed_before_send` or `unknown` after.
  `unknown` counts as done for dedupe and is never retried automatically; a person must release it.
- All approvals (build, deploy, batch, graduation) use one scheme: 32 random bytes, base64url, shown once; only
  `sha256(token)` is stored; atomic single-use claim; TTL 24 hours; bound to the exact hashes they approve.
- One canonicaliser for every hash: RFC 8785 JCS, implemented once in `packages/contracts`.
- Kill switches at tenant, workspace, member and routine scope stop all commits at once.
- Models never open a gate.

## Consequences
- The old workflow token (stored in plain text, no TTL) and the old batch hash (plain `JSON.stringify`) are replaced.
  Old approvals do not carry over.
- Two approvals exist for a fix: OK, build and deploy. After deploy, commits still ask by default ([ADR 0016](0016-no-dry-run.md)).

## Alternatives considered
- Trust a model-based "is this safe" check. Rejected: non-deterministic.

## Sources
Old ADR 0006, 0015, 0105, 0106, 0112-review-b, 0113-round-2; old `brain/src/workflows/{gate,batch}.ts`, `builder/approval.ts`.
