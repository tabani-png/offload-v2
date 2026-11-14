# 0023. Four services, ingest inside the API service

Status: accepted · Date: 2026-11-14

## Context
The brief suggested `services/{api,ingest,brain,builder,runtime}` "or fewer, justify". The first deployment serves a
tenant of one.

## Decision
- Four services, each a Bun process with its own entry point:
  - `services/api`: Hono HTTP edge. Public REST `/v1`, device ingest `/v1/ingest/*`, the Offload MCP server `/mcp`,
    inbound webhooks `/v1/hooks/*`, auth. Stateless.
  - `services/brain`: understanding, user model, opportunity finder, fix designer, model router. Batch and event driven.
  - `services/builder`: build orchestrator, sandbox provider, verifier, receipts.
  - `services/runtime`: routine runtime, connectors, gate, item journal, hs-1 measurement.
- **Ingest is a module of the API service, not its own service.** It shares auth, rate limiting, the HTTP stack and
  Postgres with the rest of the API; it does no heavy work (validate, scan, insert, emit `observations.ingested`).
  Splitting it later is a deploy change, because it already has its own route prefix and module.
- Services talk through Postgres: durable workflows and an outbox table `events_outbox` ([API.md](../API.md#6-internal-events)).
  No message broker.
- Self-host may run all four in one process (`offload serve --all`, added in M8); the code keeps them separable.

## Consequences
- Builder and runtime can scale and be isolated separately (they hold the riskiest work).

## Alternatives considered
- One service: simpler, but builder failures and sandbox traffic would share a process with the API.
- Five services: an ingest service with no distinct work.

## Sources
Owner brief.
