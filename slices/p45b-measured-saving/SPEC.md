---
id: p45b-measured-saving
title: Measured saving after a fix ships - four weekly windows, ended weeks measured once, purged weeks never guessed, partial weeks scaled, the 4-week median against the estimate as Figures
milestone: M4
status: ready
depends_on: [p45a-build-loop]
parallel_safe: true
human_gated: false
model_tier: sonnet
size: S
parallel_group: M4-A
owns: [packages/hours-saved/src/measured/**]
verify: bash slices/p45b-measured-saving/verify.sh
min_tests: 12
paths_in_scope: [services/builder/**, packages/hours-saved/src/measured/**, packages/hours-saved/tests/p45b-measured-saving/**, packages/hours-saved/src/index.ts, slices/p45a-build-loop/**, slices/p45b-measured-saving/**, NOTICE, docs/API.md, docs/DATA_MODEL.md, docs/MIGRATION.md]
paths_out_of_scope: [ee/**, apps/**, .github/**, docs/adr/**, packages/db/**, packages/contracts/**, packages/policy/**, packages/testkit/**, services/api/**, services/runtime/**, services/brain/**, packages/hours-saved/src/core/**, package.json, bun.lock]
red_tests: [SHIP, MEASURE, FLAG, MONTH, OUTCOME, FIGURE]
---

# p45b-measured-saving

## Summary
Ports old `brain/src/builder/outcomes.ts` (PR #45) and the per-week measurement fix of `473cafb` into
`packages/hours-saved/src/measured/`, as [MIGRATION section 5.6](../../docs/MIGRATION.md#56-pr-45-featbuild-loop-s35-ok-build)
plans. It is the fix-outcome part of [M4](../../docs/ROADMAP.md#m4-measured-saving-loop-closed) and
[ADR 0022](../../docs/adr/0022-hours-saved-hs-1.md): after a fix ships, four weekly windows; each ended week is measured
once, from its own stored days only; a week whose raw days were purged first says so and is never guessed; a week
with some stored days is scaled × 7 / days stored; after 4 weeks the median measured saving is compared with the
estimate (`on_track` ≥ 80%, `partial` ≥ 50%, else `under`; `unmeasured` when no week was measured; `pending` until
then), with the arithmetic as Figures ([ADR 0003](../../docs/adr/0003-numbers-come-from-code.md)). Pure functions;
the caller (m4-02/m4-03 in the runtime and brain) supplies the measurement and stores `fix_outcomes`.

## Contract
- New files only under `packages/hours-saved/src/measured/`; `src/index.ts` gains type exports only (the hs-1 port,
  m4-01, owns the package's method and its smoke test is kept).
- Constants in code: `WEEKS_TRACKED = 4`, `ON_TRACK = 0.8`, `PARTIAL = 0.5`.
- `recordShip({ routine_id, task_key, shipped_at, estimated_minutes_per_week, baseline_minutes_per_week })` →
  `FixOutcome` (the `fix_outcomes` row of [DATA_MODEL section 7](../../docs/DATA_MODEL.md#7-routines-and-runs)).
  `measureDue(outcome, { now, raw_ttl_days, measureWeek })` → the outcome with ended weeks measured;
  `measureWeek(task_key, start, end)` returns `{ minutes, days_stored }` or null.
- `summarize` returns the flag, ratio and Figures `{ id, value, unit, arithmetic, evidence[], source_purged_at }` with
  `id = fig_ + first 16 hex of sha256(JCS(figure without id))`.
- `monthOutcomes(outcomes, month_start, month_end)` for the month record.

## Red tests (write these first, run them, see them fail)
Tests live in `packages/hours-saved/tests/p45b-measured-saving/`.

| Tag | Test name | Old source |
|---|---|---|
| SHIP | records the estimate, the baseline and four empty weekly windows; refuses non-finite or negative minutes; never overwrites a shipped outcome | outcomes, routes-hardening |
| MEASURE | only ended weeks, each once, at its own end; purged weeks say so; a week from its own stored days only; partial weeks × 7 / days stored | outcomes, routes-hardening |
| FLAG | the median measured saving against the estimate, with the arithmetic | outcomes |
| OUTCOME | 80% is `on_track`, 50% `partial`, 49% `under` (ROADMAP M4) | ROADMAP M4 |
| MONTH | each fix whose 4 weeks ended in the month, with flag and arithmetic | outcomes |
| FIGURE | every number is a Figure with its arithmetic, evidence and a stable id | ADR 0003 |

## Out of scope
The hs-1 method and its 98 tests (m4-01). Where measurements come from and the `fix_outcomes` table (m4-02, m4-03).
The "Keep it?" question and ranking feedback (m4-03).

## Verify
`bash slices/p45b-measured-saving/verify.sh`.

## Scope changes
- `paths_in_scope` is shared with `p45a-build-loop` (one port, two slices).
