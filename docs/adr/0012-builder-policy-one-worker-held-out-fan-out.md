# 0012. Builder policy: 1 worker + held-out check, fan out on failure, $4 cap

Status: accepted · Date: 2026-11-14

## Context
Bench (2026-11-14, 6 briefs, 42 builds): one Sonnet worker passed the frozen check 6/6 at about 1/6 the cost of
best-of-4. **Held-out checks were the real signal**: 10 of 42 builds that passed the visible check failed an
independent one. Picking a winner by mutation score did not pick the better build (4/6 winners passed held-out).
The owner set a **$4 cap per build**.

## Decision
Before approval (fix designer, [ARCHITECTURE section 7](../ARCHITECTURE.md#7-fix-designer)):
1. Opus writes the fix brief (numbers from code).
2. A check writer (Opus) writes the **check set** (frozen acceptance checks) from the brief's acceptance lines.
3. A separate call (Opus, fresh context, different prompt, never sees the check set) writes the **held-out check**.
4. The builder assembles **replay fixtures** from the user's recorded task instances (masked), at least 3 when available.
5. **Teeth gate**: each check (frozen and held-out) must fail on an empty workspace and must leave the workspace
   unchanged. A check that fails the gate is rewritten once, then the opportunity is marked `needs_you`.
6. All hashes are fixed: `brief_hash`, `check_set_hash`, `held_out_hash`, `fixture_set_hash`.

OK, build (exact-hash approval over those four hashes plus `cap_usd = 4.00`). Then:
1. **One worker** (Sonnet) in a fresh sandbox, with the brief, the check set and the fixtures. It may run the check set
   mid-build through a `run_checks` tool. Caps per attempt: **$0.80, 40 turns, 12 minutes**. Up to 2 tries inside the
   attempt, with the frozen check output fed back.
2. On frozen-check pass: run **replay fixtures** and the **held-out check** in a fresh sandbox.
3. All pass → **verifier** (Opus, cap **$0.30**) compares the artifact with the brief's intent. Pass → `ready`.
4. Any failure (frozen, replay, held-out or verifier) → **fan out to 3 more workers** in parallel, each in its own
   sandbox, same caps. They see the frozen check output of the first attempt; they never see the held-out check or its
   output, only that it failed.
5. Winner among passing attempts: **held-out pass, then mutation score, then smallest diff** (lines changed excluding checks).
6. Budget ledger enforces a hard stop at **$4.00**. Worst planned case is $0.80 + 3 × $0.80 + $0.30 = $3.50, leaving
   $0.50 for verifier retries and overhead. Reaching the cap ends the build as `capped`.
7. Every attempt runs with superpowers TDD skills loaded and a tdd-guard-style PreToolUse hook (no source edit before
   a failing test exists).
8. Output: artifact (object storage, `artifact_sha256`) + signed build receipt. Then the **deploy approval** is a second,
   separate OK ([ADR 0016](0016-no-dry-run.md)).

Pre-approval spend (brief, checks, held-out) is not part of the $4 cap. It has its own **design budget**, default
$0.60 per opportunity ([OQ-07](../OPEN_QUESTIONS.md#oq-07-design-budget-before-ok-build)).

## Consequences
- Most builds cost well under $1 (bench: $0.05 to $0.15 per single attempt).
- The UI shows spend against the $4.00 cap and which stage is running.
- Bench must be made harder (multi-file, modify existing code, ambiguous inputs) and re-run on every builder change.

## Alternatives considered
- Best-of-4 by default: no pass-rate gain on the bench at about 6x cost.
- Winner by mutation score first: failed on the bench.

## Sources
`/workspace/offload-bench/README.md`; research Page "approve → build → ship"; old `brain/src/builder/*`; branch `feat/build-loop`.
