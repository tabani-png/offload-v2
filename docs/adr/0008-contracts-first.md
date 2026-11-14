# 0008. Contracts first, one package

Status: accepted · Date: 2026-11-14

## Context
The old repo mirrored DTOs by hand between TypeScript and Swift, split route types per slice, and had JSON Schemas in
a separate folder. Drift caused bugs.

## Decision
- `packages/contracts` is the single source of every wire shape: REST bodies, device ingest batches, MCP tool inputs
  and outputs, webhook payloads, internal events, error envelope.
- Each contract is written as a **zod** schema (zod 4) and exported as **JSON Schema 2020-12** by a generator script.
  The JSON Schemas are committed under `packages/contracts/schemas/` and are what other languages consume.
- Swift types for the Mac client are generated from the JSON Schemas (generator chosen in M1; quicktype is the
  candidate). Generated files are committed and a CI check fails if they are stale.
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

## Sources
Old `schemas/` (Draft 2020-12), old `control/src/schema/`, old `brain/src/api/types.ts`.
