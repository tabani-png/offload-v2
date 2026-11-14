# 0029. Build verdicts: fresh-sandbox pass, one repair turn, held-out per build

Status: accepted, revised 2026-11-14 · Date: 2026-11-14

## Context
The previous design took "frozen checks pass" from the worker's own sandbox, where the agent has Bash as the same uid
as the harness and can read the nonce or print `OFFLOAD_PROOF` itself: the same-uid lesson of
[ADR 0011](0011-sandboxed-build-workers.md). A Claude Code review of PR #45 found a fake-pass hole of this kind.
An LLM verifier's false fail triggered a full fan-out. Reusing a held-out check across retries leaks it
([design review C (2026-11-14)](../SOURCES.md#design-review-c), P1(2)).

## Decision
- **The only pass that counts** is frozen checks + replay fixtures + held-out check re-run in a **fresh verification
  sandbox** created from the attempt's artifact (5 minutes, 2 vCPU). The in-worker `run_checks` tool is advisory.
  Check shards may run in parallel sandboxes that split one verification's sandbox reservation
  ([ADR 0030](0030-build-budget-at-egress-proxy.md)); any failing shard is a fail.
- **Fan out only on check failures** (frozen, replay or held-out), never on a verifier fail.
- **Verifier** (Opus, cap $0.25) fail → **one repair turn** to the same worker with the verifier's reasons (cap $0.15),
  re-verified in a fresh sandbox, then the verifier runs again. A second verifier fail ends the build `failed` (state
  `repairing` during the turn).
- **Winner** among passing attempts: replay + held-out pass, then smallest diff (lines changed, excluding checks).
  Mutation score is not used ([OQ-21](../OPEN_QUESTIONS.md#oq-21-drop-mutation-score-from-the-build-winner-rule)).
- **A new build of the same brief regenerates the held-out check**: a retry after `failed`, `capped` or
  `infra_failed`-final, and a routine repair. The regeneration is design spend, not build spend.

## Consequences
- A worker cannot fake a pass. A verifier's false fail costs at most $0.15 + $0.25 + one sandbox.
- Retries cost one extra held-out generation (bench: about $0.10).

## Alternatives considered
- Trust the harness inside the worker sandbox: the same-uid problem.
- Fan out on verifier fail: costly for an LLM judgement.
- Keep one held-out check per brief forever: retries learn it.

## Sources
[Design review C (2026-11-14)](../SOURCES.md#design-review-c), P1(2); PR #45 (fake-pass hole fixed in review; mutation scoring dropped); [builder bench report](../SOURCES.md#builder-bench-report).

## Revisions

- 2026-11-14 (final pass): shards split one verification's sandbox reservation (final-pass audit).
