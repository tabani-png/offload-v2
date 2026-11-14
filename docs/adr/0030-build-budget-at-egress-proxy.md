# 0030. Build budget enforced at the model egress proxy

Status: accepted, revised 2026-11-14 · Date: 2026-11-14

## Context
The orchestrator checked the budget "before each call", but calls are made by the Agent SDK inside the sandbox, where
the orchestrator cannot see them. Parallel fan-out workers could overshoot together. The old worst-case arithmetic left
out the first verifier run and all sandbox minutes ([design review C (2026-11-14)](../SOURCES.md#design-review-c), P1(2), [design review A (2026-11-14)](../SOURCES.md#design-review-a), #52/#53, [design review B (2026-11-14)](../SOURCES.md#design-review-b), 19).

## Decision
- Each attempt gets an **attempt-scoped token** for the model egress proxy. The sandbox has no API key; the proxy adds
  it.
- Per call, the proxy **reserves the worst case**: `est_input_tokens × input price + max_tokens × output price`, in
  `budget_reservations`, atomically under a row lock on the `builds` row, against `4.00 − settled − reserved`. If the
  reservation does not fit, the call is refused and the attempt ends.
- On response the proxy **settles** the actual cost into `budget_entries` (unique idempotency key = call id) and
  releases the reservation. Prices come from config ([ADR 0021](0021-model-router-and-builders.md)).
- **Fan-out pre-allocates** each worker's full cap before it starts, so parallel workers cannot overshoot.
- **Sandbox time counts toward the cap**: sandbox seconds are reserved at creation (wall cap × vCPU) and billed at the
  configured `sandbox_usd_per_vcpu_second`.
- Caps: worker attempt **$0.70** (40 turns, 12 minutes, up to 2 tries inside); verifier **$0.25**; repair turn
  **$0.15**; verification sandbox **5 minutes**. All sandboxes have 2 vCPU.
- **Worst-case model spend**: $0.70 + 3 × $0.70 + $0.25 + $0.15 + $0.25 = **$3.45** (first worker, three fan-out
  workers, verifier, repair turn, verifier again).
- **Worst-case sandbox time**: 4 worker sandboxes × 12 min + 5 verification sandboxes × 5 min = 73 min × 2 vCPU =
  **8,760 vCPU-seconds**. Two rules keep this true: a verification's reservation is 5 minutes × 2 vCPU = 600
  vCPU-seconds whether it runs as one sandbox or as parallel check shards (shards split that reservation, for example
  two 1-vCPU shards); and the repair turn runs in its worker's sandbox inside that worker's 12-minute wall cap.
- The plan holds when 8,760 × rate ≤ $0.55, that is a rate of at most **$0.0000627 per vCPU-second**. Above that, the
  reservation refuses the last work and the build ends `capped`. The hard stop is **$4.00** for model and sandbox
  together.
- Design spend (fixture capture, brief, checks, held-out) is separate ([OQ-07](../OPEN_QUESTIONS.md#oq-07-design-budget-before-ok-build)).
  Infrastructure-failure spend is recorded with scope `infra` and not billed to the cap ([ADR 0031](0031-build-infrastructure-failures.md)).
- M2 runs with one retry worker (`fanout_workers = 1`); M6 sets 3. The arithmetic above is for 3.

## Consequences
- The cap is a property of the proxy and the database, not of the agent's good behaviour.
- Reservations make the displayed "spent" lag slightly behind "reserved"; the UI shows both.

## Alternatives considered
- Check in the orchestrator before each call (the previous version): it cannot see the calls.
- Provider-side spend limits: per organisation, not per build.

## Sources
[Design review C (2026-11-14)](../SOURCES.md#design-review-c), P1(2); [design review A (2026-11-14)](../SOURCES.md#design-review-a), #52, #53, #119; [design review B (2026-11-14)](../SOURCES.md#design-review-b), 19; owner decision ($4 cap).

## Revisions

- 2026-11-14 (final pass): worst-case sandbox time made explicit for check shards and the repair turn (final-pass audit).
