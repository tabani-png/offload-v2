# 0022. Measured hours saved: hs-1

Status: accepted · Date: 2026-11-14 · Carries over old ADR 0109 and `packages/hours-saved` unchanged in method

## Context
"Hours saved" must be measured, not estimated, and must be reproducible.

## Decision
- `packages/hours-saved` is ported **as is** (pure, integer seconds, 98 tests, golden fixtures). Only its input
  adapters change: baselines now come from the cloud task ledger instead of Mac uploads.
- **Baseline** per `(routine_id, version)`: active seconds of the task's recorded instances before deploy, deduplicated
  by instance ref. Median (even n: floor of the mean of the two middle values); q1/q3 nearest rank `d[ceil(p·n)−1]`;
  `iqr = q3 − q1`. Grade **A** = observed, n ≥ 5 and 2·iqr ≤ median; **B** = other observed; **C** = user estimate.
- **Residual** per run = review + edit + fix seconds from `review_event` uploads and web approvals.
- **Per run**: `saved = max(0, baseline_median × items_sent − residual)`, only for outcome `success`. No review event
  → saved 0, note `not_reviewed_yet`. Auto-committed runs use the review seconds spent on their digest.
- **Display**: `round_half_even(seconds / 360) / 10` hours. A/B shown as "measured", C as "estimated".
- Every result carries `computation: "hs-1"` and `inputs_digest = sha256(JCS(sorted rows))`. A nightly recompute that
  disagrees blocks the "final" badge.
- **Realized vs estimated**: for 4 weeks after deploy the week record compares measured hours with the fix designer's
  estimate. Below 50% for 4 weeks → the weekly review asks "Keep it?" (keep / undo).
- Measured savings flow back into the user model (fix outcomes by kind lower or raise confidence for later rankings).
- Team aggregates keep the group floor of 5 with complementary suppression (old ADR 0103).

## Consequences
- The same method serves the Mac, the web app and Enterprise reports.

## Alternatives considered
- Model-estimated savings: violates [ADR 0003](0003-numbers-come-from-code.md).

## Sources
Old ADR 0109; old `packages/hours-saved/src/{core,aggregate,report,digest}.ts`.
