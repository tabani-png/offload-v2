# 0019. User model in Postgres (bi-temporal tables, pgvector); graph port with optional graphiti

Status: accepted, revised 2026-11-14 · Date: 2026-11-14

## Context
The user model must remember months of derived facts (who, what, how long, since when, still true or not) without raw
screen data. The spec recommended graphiti + gum. graphiti needs a graph backend: FalkorDB (source-available,
SSPL-style), Neo4j Community (GPLv3), Amazon Neptune (managed, AWS only) or Kuzu (archived; verify the date before
citing it). gum is a small MIT research prototype whose screen observer must never be used. PR #43 (s36) reimplemented
the gum and graphiti shapes in TypeScript in the old repo.

## Decision
- Store the user model **in Postgres**, in tables designed after graphiti and gum ([DATA_MODEL.md](../DATA_MODEL.md#4-user-model)):
  `episodes`, `entities`, `facts` (bi-temporal: `valid_at`, `invalid_at`, `recorded_at`, `expired_at`),
  `propositions` (confidence 1 to 10, decay 1 to 10, `revision_group`, `version`), `task_ledger`, `day_records`,
  `week_records`, `month_records`, `quarter_records`, `profiles`, `goals`.
- Embeddings in **pgvector** (`vector(1024)` default; the embedding model is configured per deployment). Queries use an
  **exact scan** filtered by tenant and member. No HNSW index until measured: approximate indexes recall poorly on tiny
  per-member sets.
- People and documents are **stable keyed pseudonyms** from the Mac ([ADR 0028](0028-stable-keyed-pseudonyms.md)).
  Entity resolution follows the splink pattern (blocking + pairwise scores) over pseudonyms and masked attributes, in
  TypeScript. A display name exists only on the Mac (device-side reveal) or after the user confirms one.
- A **`MemoryGraphPort`** (`upsertEpisode`, `resolveEntities`, `assertFact`, `invalidateFact`, `factsAt(time)`,
  `neighbors`, `forgetEntity`, `exportAll`) has the Postgres adapter as default. A **graphiti adapter** (Python sidecar
  over loopback HTTP, telemetry off) is an optional plug-in, **not shipped in the default distribution**, because its
  backends carry SSPL-style or GPLv3 terms or are cloud-only ([OQ-14](../OPEN_QUESTIONS.md#oq-14-optional-graphiti-adapter-and-graph-backend-licenses)).
- gum's ideas (propose, revise, decay, confidence from evidence) are reimplemented in TypeScript with confidence
  computed by rules from evidence counts (PR #43 formula), never by a model.
- Raw `C1` observations expire at their TTLs. Derived records keep `evidence` id lists; once raw data is gone they
  render `source_purged`.
- Forget: entity, date range, import, or everything; cascade to facts, propositions and embeddings; logged to
  `purge_log`.

## Consequences
- Self-host needs only Postgres for the full user model.
- We write more code than calling graphiti, but it is plain SQL and testable with golden fixtures.

## Alternatives considered
- graphiti + FalkorDB as default: license and a second datastore.
- Mem0 / Cognee: weaker time semantics (spec section 7).

## Sources
[product spec (M0 to M9)](../SOURCES.md#product-spec-m0-to-m9) sections 3, 4, 7; PR #43 (`brain/src/usermodel`, gum MIT and graphiti Apache-2.0
credited in its `NOTICE.md`); repo-scout log.

## Revisions
- 2026-11-14: Kuzu date marked "verify", Amazon Neptune listed ([design review B (2026-11-14)](../SOURCES.md#design-review-b), 25); exact scan instead of HNSW ([design review C (2026-11-14)](../SOURCES.md#design-review-c), P2);
  people as stable keyed pseudonyms ([design review C (2026-11-14)](../SOURCES.md#design-review-c), P0-4).
