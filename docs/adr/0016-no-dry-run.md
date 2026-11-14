# 0016. No dry run: verify inside the build, ask before commit after deploy

Status: accepted, revised 2026-11-14 · Date: 2026-11-14 · Supersedes the old "dry run on last week" step (old CONTEXT.md, s05, s14, s27, old ADR 0106 `dryRunNights`)

## Context
The old product ran each workflow on last week's instances "without side effects" and showed it next to what the
user did, called a "dry run". The s34 branches renamed it "Preview from your last week" (PR #41). The owner said
dry-run stuff should not be in the product.

## Decision
- There is **no dry-run stage** in the product, the API, events or copy. No endpoint, state, field or string may be
  called "dry run", "dry-run", "dry_run" or "preview run".
- Verification happens **inside the build**, before "Ready to ship":
  1. frozen acceptance checks (check set),
  2. a held-out check never shown to workers,
  3. **replay of the user's real instances** as test fixtures in a fresh sandbox. The fixtures come from **fixture
     capture** before approval: read-only connector reads of his last real instances and of what he produced
     ([ADR 0027](0027-fixture-capture-and-connector-content.md)). Every connector is replaced by a fake that returns
     the recorded reads; commit steps return items, which are asserted against the recorded results, never executed.
- After deploy, **commit steps start in `ask_before_commit`**: each run prepares its batch and the user approves it
  (one tap, exact batch hash). Read and draft steps run freely.
- **Graduation** to `auto_commit` is a policy decision: the core policy proposes graduation after a threshold of clean
  runs (default 5 consecutive approved runs with no edits and no `failed_before_send` or `unknown` items,
  [OQ-09](../OPEN_QUESTIONS.md#oq-09-graduation-threshold)) and the user confirms with one tap. EE policies can change
  the threshold or require more approvers. Any user edit, failure or circuit breaker resets the count. Browser commits
  never graduate.

## Consequences
- The old `GateMode = dry_run` is gone. Gate modes are `read` (connector reads only: fixture capture, instant read) and
  `live` ([ADR 0004](0004-every-external-action-is-gated.md)).
- When fewer than 3 real instances exist, the build says so and relies on checks and the held-out check.

## Alternatives considered
- Keep it but rename it. Rejected: same ceremony, and the owner asked for it to be removed.

## Sources
Owner brief; old `plan/CONTEXT.md` ("Dry run"); PR #41 (`release/mac-testable` commit `c85ef44`, no dry-run ceremony).

## Revisions
- 2026-11-14: replay fixtures come from fixture capture of connector reads, not from screen observations (review-c
  P0-3); gate modes defined (review-a #81).
