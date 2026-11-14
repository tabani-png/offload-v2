# 0008. Contracts first, one package

Status: accepted, revised 2026-11-14 · Date: 2026-11-14

## Context
The old repo mirrored DTOs by hand between TypeScript and Swift, split route types per slice, and had JSON Schemas in
a separate folder. Drift caused bugs.

## Decision
- `packages/contracts` is the single source of every wire shape: REST bodies, device ingest batches, device commands,
  MCP tool inputs and outputs, webhook payloads, internal events, error envelope.
- Each contract is written as a **zod** schema (zod 4, exact pin) and exported as **JSON Schema 2020-12** by a generator
  script. The JSON Schemas are committed under `packages/contracts/schemas/` and are what other languages consume.
- Swift types for the Mac client are generated from the JSON Schemas by a dependency-free emitter
  (`packages/contracts/scripts/gen-swift.ts`) into the `OffloadContracts` target
  (`apps/mac/Sources/OffloadContracts/Generated/`), which every other Mac target depends on. The Swift JCS
  implementation lives beside it and shares the RFC 8785 test vectors with the TypeScript one. Generated files are
  committed and a test fails if they are stale.
- The routine artifact schema (`routine.json`) lives in `packages/routine-sdk`, which depends on contracts
  ([ADR 0026](0026-routine-artifact-contract.md)).
- Every contract has a version. Public REST is versioned in the path (`/v1`). Events carry `type` and `version`.
- Contract changes land first, in their own slice, with fixtures, before any implementation that uses them.
- `packages/contracts` has no runtime dependency on Bun APIs, so the web app can import it.
- The one canonicaliser (RFC 8785 JCS) and the hash helpers live here.

## Consequences
- Agents read the contract, not the implementation, to know a shape.
- Breaking a contract needs a new version, not an edit.

## Alternatives considered
- TypeBox (JSON Schema native). Close second. zod chosen because the old brain used zod and it has wider agent familiarity.
- OpenAPI-first with codegen to TS. Heavier; MCP tools and events are not HTTP.
- quicktype for Swift generation: another dependency for a small emitter ([design review A (2026-11-14)](../SOURCES.md#design-review-a), #11).

## Sources
Old `schemas/` (Draft 2020-12), old `control/src/schema/`, old `brain/src/api/types.ts`.

## Revisions
- 2026-11-14: Swift generator chosen (dependency-free emitter) and target `OffloadContracts` named ([design review A (2026-11-14)](../SOURCES.md#design-review-a), #11, #45,
  #46); routine schema in `packages/routine-sdk` ([design review C (2026-11-14)](../SOURCES.md#design-review-c), P0-2).
