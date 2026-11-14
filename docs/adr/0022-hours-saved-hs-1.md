# 0022. Measured hours saved: hs-1 and fix outcomes

Status: accepted, revised 2026-11-14 · Date: 2026-11-14 · Carries over old ADR 0109 and `packages/hours-saved` unchanged in method

## Context
"Hours saved" must be measured, not estimated, and must be reproducible. The spec (§4.4) also asks that a fix that
does not pay off is flagged. PR #45 implemented fix outcomes in the old repo (`brain/src/builder/outcomes.ts`).

## Decision
- `packages/hours-saved` is ported **as is** (pure, integer seconds, 98 tests, golden fixtures). Only its input
  adapters change: baselines now come from the cloud task ledger instead of Mac uploads.
- **Baseline** per `(routine_id, version)`: active seconds of the task's recorded instances before deploy, deduplicated
  by instance ref. Median (even n: floor of the mean of the two middle values); q1/q3 nearest rank `d[ceil(p·n)−1]`;
  `iqr = q3 − q1`. Grade **A** = observed, n ≥ 5 and 2·iqr ≤ median; **B** = other observed; **C** = user estimate.
  The hand-fed loop (M2, M4) starts at grade C; grade A arrives with capture (M3, M5).
- **Residual** per run = review + edit + fix seconds from `review_event` uploads and web approvals.
- **Per run**: `saved = max(0, baseline_median × items_sent − residual)`, only for outcome `success`. No review event
  → saved 0, note `not_reviewed_yet`. Auto-committed runs use the review seconds spent on their digest.
- **Display**: `round_half_even(seconds / 360) / 10` hours. A/B shown as "measured", C as "estimated".
- Every result carries `computation: "hs-1"` and `inputs_digest = sha256(JCS(sorted rows))`. A nightly recompute that
  disagrees blocks the "final" badge.
- **Fix outcomes** (as in PR #45 `outcomes.ts`): for 4 weeks after a fix ships, each week's measured minutes for the
  task are recorded at the week's end. Saved per week = baseline − measured. The verdict compares the **median** saved
  minutes with the estimate: `on_track` when the ratio is ≥ 0.8, `partial` when ≥ 0.5, `under` below that,
  `unmeasured` when no week could be measured, `pending` until all 4 weeks are complete. A week whose raw data was
  purged before it was measured is `source purged` and never guessed.
- **Two flags**: the weekly review asks "Keep it?" (keep / undo) when a fix is `under`; and, per spec §4.4, a fix that
  misses its estimate by 50% or more over its first 4 weeks is flagged in the month record with "Didn't pay off: undo?".
- Measured savings flow back into the user model (outcomes by fix kind lower or raise confidence for later rankings).
- Team aggregates keep the group floor of 5 with complementary suppression (old ADR 0103).
- The field name is `items_sent` everywhere.

## Consequences
- The same method serves the Mac, the web app and Enterprise reports.
- Outcome thresholds are constants in code (`ON_TRACK = 0.8`, `PARTIAL = 0.5`, `WEEKS_TRACKED = 4`), tested.

## Alternatives considered
- Model-estimated savings: violates [ADR 0003](0003-numbers-come-from-code.md).

## Sources
Old ADR 0109; old `packages/hours-saved/src/{core,aggregate,report,digest}.ts`; PR #45 `brain/src/builder/outcomes.ts`;
[product spec (M0 to M9)](../SOURCES.md#product-spec-m0-to-m9) §4.4.

## Revisions
- 2026-11-14: outcomes thresholds from `outcomes.ts` and the spec's monthly flag ([design review B (2026-11-14)](../SOURCES.md#design-review-b), 18); `items_sent` naming
  ([design review A (2026-11-14)](../SOURCES.md#design-review-a), #79); grade C start for the hand-fed loop ([design review C (2026-11-14)](../SOURCES.md#design-review-c), §9).
