# 0003. Numbers come from code, never a model

Status: accepted, revised 2026-11-14 · Date: 2026-11-14 · Carries over old ADR 0005

## Context
Offload's value is trust in its numbers: hours, savings, counts, scores. A model that writes numbers can invent them.

## Decision
- Every number shown to a user or used in a decision is computed by deterministic code: durations, counts, savings,
  scores, baselines, costs, trends, hs-1.
- Every figure carries `arithmetic` (a human-readable formula with the inputs) and `evidence` (ids of observations,
  episodes, runs or connector reads). When the raw evidence has passed its TTL, the figure says `source_purged` with
  the date and is never re-derived.
- Models may only: name things, classify within fixed vocabularies, return a **label from a fixed enum** for judgement
  or risk (for example `low | medium | high`), write drafts, and write narrative. Code maps each label to a number
  with a fixed table; the model never produces the number.
- Narrative checker: any model text that contains a number is checked in code against the record it describes. A number
  not present in the record makes the text invalid and it is refused (harvested from `checkNarrative`, PR #43).
- No totals from partial lists (old ADR 0114 rule).

## Consequences
- Every API figure type has `{ id, value, unit, arithmetic, evidence, source_purged_at }` ([API.md](../API.md#figure)).
- Tests use golden fixtures with exact expected JSON.

## Alternatives considered
- Let the model estimate savings and label them estimates. Rejected: the old blind test showed estimates drift.
- Let the model score within bounds. Rejected: a bounded number is still a model number ([design review A (2026-11-14)](../SOURCES.md#design-review-a), #59).

## Sources
Old ADR 0005 (via `plan/plan.md` Decisions), 0009, 0011, 0015, 0109, 0114; PR #43 `checkNarrative`.

## Revisions
- 2026-11-14: models return labels from a fixed enum, code maps them to numbers ([design review A (2026-11-14)](../SOURCES.md#design-review-a), #59); Figure carries an id.
