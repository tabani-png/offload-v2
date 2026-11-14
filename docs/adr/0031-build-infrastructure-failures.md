# 0031. Build infrastructure failures: `infra_failed` and the sandbox reaper

Status: accepted · Date: 2026-11-14

## Context
There was no state for a sandbox provider outage, model 429/529, an orchestrator crash with an orphaned microVM, or an
egress-proxy failure. Such failures would burn the user's single-use OK and his $4.00 on something that was not his
build's fault (review-c P1(2)).

## Decision
- New build state **`infra_failed`** for: sandbox provider errors or outage, model 429/529 still failing after the
  attempt's own retries, egress-proxy failure (fail closed), and an orchestrator crash that leaves a build without a
  live workflow.
- `infra_failed` is retried automatically up to 3 times with backoff within 1 hour, then becomes final and the user
  can retry from Build progress.
- Spend during an infrastructure failure is recorded in `budget_entries` with scope `infra` and **is not billed to the
  cap**.
- If the build had **no model spend**, the orchestrator sets `approvals.released_at` (once). A released approval may be
  claimed exactly once more, so a retry needs no new OK. With model spend, a retry needs a new OK and regenerates the
  held-out check ([ADR 0029](0029-build-verdicts.md)).
- **Sandbox reaper**: every 5 minutes, a job lists provider sandboxes tagged `offload-build-<build_id>`, destroys those
  older than their wall cap + 5 minutes or whose build is in a terminal state, and writes audit `sandbox.reaped`. It
  runs as `offload_jobs` ([ADR 0013](0013-tenancy-and-rls.md)).
- `budget_entries` writes are idempotent by key (call id or step id), so a replayed step never double-bills.

## Consequences
- The user sees "Offload's side failed, retrying" instead of a failed build.
- Orphaned microVMs cost at most one reaper interval past their cap.

## Alternatives considered
- Treat infrastructure errors as `failed`: bills the user for our outage and burns the OK.
- Unlimited automatic retries: hides persistent outages.

## Sources
Review-c P1(2); PR #45 (stale locks recoverable, fan-out builders never orphaned).
