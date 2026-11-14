# 0003. Numbers come from code, never a model

Status: accepted · Date: 2026-11-14 · Carries over old ADR 0005

## Context
Offload's value is trust in its numbers: hours, savings, counts, scores. A model that writes numbers can invent them.

## Decision
- Every number shown to a user or used in a decision is computed by deterministic code: durations, counts, savings,
  scores, baselines, costs, trends, hs-1.
- Every figure carries `arithmetic` (a human-readable formula with the inputs) and `evidence` (ids of observations,
  episodes or runs). When the raw evidence has passed its TTL, the figure says `source_purged` with the date and is
  never re-derived.
- Models may only: name things, classify within fixed vocabularies, score judgement or risk within code-defined bounds,
  write drafts, and write narrative.
- Narrative checker: any model text that contains a number is checked in code against the record it describes. A number
  not present in the record makes the text invalid and it is refused (harvested from `checkNarrative`).
- No totals from partial lists (old ADR 0114 rule).

## Consequences
- Every API figure type has `{ value, unit, arithmetic, evidence }` ([API.md](../API.md#figure)).
- Tests use golden fixtures with exact expected JSON.

## Alternatives considered
- Let the model estimate savings and label them estimates. Rejected: the old blind test showed estimates drift.

## Sources
Old ADR 0005 (via `plan/plan.md` Decisions), 0009, 0011, 0015, 0109, 0114; branch `feat/user-model-gum-graphiti` `checkNarrative`.
