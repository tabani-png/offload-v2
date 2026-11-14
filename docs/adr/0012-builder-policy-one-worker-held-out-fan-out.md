# 0012. Builder policy: 1 worker + held-out check, fan out on failure, $4 cap

Status: accepted, revised 2026-11-14 · Date: 2026-11-14

## Context
Bench (2026-11-14, 6 briefs, 42 builds): one Sonnet worker passed the frozen check 6/6 at about 1/6 the cost of
best-of-4. **Held-out checks were the real signal**: 10 of 42 builds that passed the visible check failed an
independent one. Picking a winner by mutation score did not pick the better build (4/6 winners passed held-out).
The owner set a **$4 cap per build**. The old repo's s35 slice (PR #45, branch `feat/build-loop`, 2 commits, see
[MIGRATION.md](../MIGRATION.md)) implemented this loop: frozen visible check and a separate held-out check that must
both fail on an empty workspace, one test-first builder, check shards in isolated containers where any failing shard
is a FAIL, fan-out of up to 3 more builders only on FAIL, install as its own approval, $4 cap. A Claude Code review of
s35 found and fixed a fake-pass hole; v2 closes that class by taking the verdict only from a fresh sandbox.

## Decision
Before approval (fix designer in the brain, [ARCHITECTURE section 7](../ARCHITECTURE.md#7-fix-designer)):
1. The user picks an option. Missing connections put the opportunity in `needs_connection` until he connects them.
2. **Fixture capture** by the fix designer: read-only connector reads of the last real instances and their results
   ([ADR 0027](0027-fixture-capture-and-connector-content.md)). Fixtures are tokenised.
3. Opus writes the fix brief (numbers from code), naming per step the pinned connection, adapter, tool and pin hash
   ([ADR 0033](0033-pinned-connector-resolution-and-launch-catalog.md)).
4. A check writer (Opus) writes the **check set** (frozen acceptance checks) from the brief's acceptance lines, against
   the routine SDK ([ADR 0026](0026-routine-artifact-contract.md)).
5. A separate call (Opus, fresh context, different prompt, never sees the check set) writes the **held-out check**.
6. **Teeth gate**: each check (frozen and held-out) must fail on an empty workspace and must leave the workspace
   unchanged. A check that fails the gate is rewritten once, then the opportunity is marked `needs_you`.
7. All hashes are fixed: `brief_hash`, `check_set_hash`, `held_out_hash`, `fixture_set_hash`.

Pre-approval spend (fixture capture, brief, checks, held-out) has its own **design budget**, default $0.60 per
opportunity ([OQ-07](../OPEN_QUESTIONS.md#oq-07-design-budget-before-ok-build)); it is not part of the $4 cap.

OK, build (exact-hash approval over those four hashes plus `cap_usd = 4.00`). Then:
1. **One worker** (Sonnet, Agent SDK) in a fresh sandbox, with the brief, the check set and the tokenised fixtures. It
   may run the check set mid-build through a `run_checks` tool (advisory). Caps per attempt: **$0.70, 40 turns,
   12 minutes**, up to 2 tries inside the attempt with the frozen check output fed back.
2. The attempt's artifact goes to a **fresh verification sandbox**: frozen checks + replay fixtures + held-out check.
   That is the only pass that counts ([ADR 0029](0029-build-verdicts.md)).
3. Check failure → **fan out** to more workers in parallel, each in its own sandbox, same caps, each pre-allocated its
   cap. They see the frozen check output of the first attempt; never the held-out check or its output, only that it
   failed. M2 runs with one retry worker (`fanout_workers = 1`); M6 raises it to 3.
4. Winner among passing attempts: **replay + held-out pass, then smallest diff** (lines changed excluding checks).
   Mutation score is not used ([OQ-21](../OPEN_QUESTIONS.md#oq-21-drop-mutation-score-from-the-build-winner-rule)).
5. **Verifier** (Opus, cap $0.25, fresh context, sees the brief and the artifact, not the transcript). Fail → **one
   repair turn** to the same worker with the reasons (cap $0.15), re-verified in a fresh sandbox, then the verifier
   again. A second verifier fail ends the build `failed`. Verifier fails never fan out.
6. The budget is enforced at the egress proxy with reservations; the worst case is $3.45 of model spend plus sandbox
   time, all inside the $4.00 hard stop ([ADR 0030](0030-build-budget-at-egress-proxy.md)). Reaching the cap ends the
   build `capped`. Infrastructure failures end it `infra_failed`, not billed to the cap ([ADR 0031](0031-build-infrastructure-failures.md)).
7. Every attempt runs with superpowers TDD and verification skills loaded, gstack QA and ship skills, and a
   tdd-guard-style PreToolUse hook (no source edit before a failing test exists) ([ADR 0021](0021-model-router-and-builders.md)).
8. For `small_app` (from M8), the verifier also runs a visual **compare-to-brief** check: screenshots of the built app
   against the brief's described screens (craft-anything's compare-to-original).
9. Output: artifact (`routine.json` + transforms + tests, `artifact_sha256`) and a signed build receipt. Then the
   **deploy approval** is a second, separate OK that binds a readable definition ([ADR 0032](0032-deploy-approval-binds-definition.md)).
10. A new build of the same brief (retry after failure, routine repair) regenerates the held-out check.

## Consequences
- Most builds cost well under $1 (bench: $0.05 to $0.15 per single attempt).
- The UI shows spend against the $4.00 cap and which stage is running.
- Bench must be made harder (multi-file, modify existing code, ambiguous inputs) and re-run on every builder change.

## Alternatives considered
- Best-of-4 by default: no pass-rate gain on the bench at about 6x cost.
- Winner by mutation score: failed on the bench; PR #45 dropped it.
- Fan out on a verifier fail (the previous version): an LLM judge's false fail would cost $2.10 of workers.

## Sources
[builder bench report](../SOURCES.md#builder-bench-report); research Page "approve → build → ship"; old `brain/src/builder/*`; PR #45
(`loop.ts`, `heldout.ts`, `container.ts`); kortix-ai/CompanyOS (Elastic License 2.0, **ideas only, no code**:
a separate verifier that did not write the code, change requests); storytold/craft-anything (checks callable mid-build
as `run_checks`, compare-to-original for `small_app`); obra/superpowers (MIT); nizos/tdd-guard; garrytan/gstack (MIT).

## Revisions
- 2026-11-14: fixture capture by the fix designer before approval ([design review A (2026-11-14)](../SOURCES.md#design-review-a), #54, [design review C (2026-11-14)](../SOURCES.md#design-review-c), P0-3); verdict only from a
  fresh sandbox, verifier fail → one repair turn, held-out regenerated per new build ([design review C (2026-11-14)](../SOURCES.md#design-review-c), P1(2)); caps and
  arithmetic moved to ADR 0030 ([design review A (2026-11-14)](../SOURCES.md#design-review-a), #52/#53, [design review B (2026-11-14)](../SOURCES.md#design-review-b), 19); winner without mutation score ([design review C (2026-11-14)](../SOURCES.md#design-review-c), P2, PR #45);
  s35 facts and attributions ([design review B (2026-11-14)](../SOURCES.md#design-review-b), 11, 20); M2 runs one retry worker.
