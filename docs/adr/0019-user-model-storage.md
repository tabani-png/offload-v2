# 0019. User model in Postgres (bi-temporal tables, pgvector); graph port with optional graphiti

Status: accepted · Date: 2026-11-14

## Context
The user model must remember months of derived facts (who, what, how long, since when, still true or not) without raw
screen data. The spec recommended graphiti + gum. graphiti needs a graph backend: FalkorDB (source-available,
SSPL-style) or Neo4j Community (GPLv3); Kuzu was archived in October 2025. gum is a small MIT research prototype
whose screen observer must never be used.

## Decision
- Store the user model **in Postgres**, in tables designed after graphiti and gum ([DATA_MODEL.md](../DATA_MODEL.md#4-user-model)):
  `episodes`, `entities`, `facts` (bi-temporal: `valid_at`, `invalid_at`, `recorded_at`, `expired_at`),
  `propositions` (confidence 1 to 10, decay 1 to 10, `revision_group`, `version`), `task_ledger`, `day_records`,
  `week_records`, `month_records`, `quarter_records`, `profiles`, `goals`.
- Embeddings in **pgvector** (`vector(1024)` default; the embedding model is configured per deployment).
- Entity resolution follows the splink pattern (blocking + pairwise scores) implemented in TypeScript over masked
  attributes; people are salted-hash ids until the user confirms a name.
- A **`MemoryGraphPort`** (`upsertEpisode`, `resolveEntities`, `assertFact`, `invalidateFact`, `factsAt(time)`,
  `neighbors`, `forgetEntity`, `exportAll`) has the Postgres adapter as default. A **graphiti adapter** (Python sidecar
  over loopback HTTP, telemetry off) is an optional plug-in, **not shipped in the default distribution**, because its
  backends carry SSPL-style or GPLv3 terms ([OQ-14](../OPEN_QUESTIONS.md#oq-14-optional-graphiti-adapter-and-graph-backend-licenses)).
- gum's ideas (propose, revise, decay, confidence from evidence) are reimplemented in TypeScript with confidence
  computed by rules from evidence counts (harvested formula), never by a model.
- Raw `C1` observations expire at the raw TTL. Derived records keep `evidence` id lists; once raw data is gone they
  render `source_purged`.
- Forget: entity, date range, or everything; cascade to facts, propositions and embeddings; logged to `purge_log`.

## Consequences
- Self-host needs only Postgres for the full user model.
- We write more code than calling graphiti, but it is plain SQL and testable with golden fixtures.

## Alternatives considered
- graphiti + FalkorDB as default: license and a second datastore.
- Mem0 / Cognee: weaker time semantics (spec section 7).

## Sources
`/workspace/offload-app/spec.md` sections 3, 4, 7; branch `feat/user-model-gum-graphiti`; repo-scout log.
