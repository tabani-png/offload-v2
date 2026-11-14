# 0002. TypeScript strict on Bun, Hono, Postgres 17 as the one required datastore

Status: accepted · Date: 2026-11-14

## Context
The old brain and control plane are Bun + TypeScript, with Hono on `Bun.serve` and Postgres 17 (old ADR 0110). The team
and agents know this stack. Self-hosters need a small footprint.

## Decision
- Cloud services: TypeScript in `strict` mode on Bun 1.3 or later (the box and CI pin 1.4.4). HTTP with Hono.
- **Postgres 17 is the one required datastore.** It holds tenancy (RLS), the user model (bi-temporal tables), vectors
  (pgvector), the durable runtime's state ([ADR 0009](0009-durable-execution-on-postgres.md)), the audit log and the
  budget ledger.
- Object storage: any S3-compatible bucket for artifacts, fixtures and exports. Dev uses a local-disk adapter. We do not
  ship MinIO (AGPL) in our compose file.
- Self-host therefore needs Postgres + object storage, nothing else.
- Python only where a library forces it, as an optional sidecar (for example the graphiti adapter, [ADR 0019](0019-user-model-storage.md)).
- Versions are pinned exactly (`bunfig.toml` `exact = true`). A new dependency needs a line in the slice SPEC and, if it
  is a new runtime component, an ADR.
- TypeScript 7.0.2 is the pinned compiler (`bunx tsc --noEmit -p tsconfig.json` is the typecheck).

## Consequences
- One database to back up, encrypt and replicate. RLS and pgvector must stay healthy under load; measure in M3.
- Bun-specific APIs (`Bun.sql`, `Bun.serve`) are allowed in services but not in `packages/contracts`, which must also
  load in the browser.

## Alternatives considered
- Node.js + Fastify: fine, but no gain and loses the old code.
- Separate vector DB (Qdrant, LanceDB) or graph DB (Neo4j, FalkorDB): more to self-host; licensing issues for graph DBs.
- Go or Rust services: would discard the harvested TypeScript.

## Sources
Old ADR 0110, old `control/package.json`, [repo-scout log](../MIGRATION.md#inputs-read).
