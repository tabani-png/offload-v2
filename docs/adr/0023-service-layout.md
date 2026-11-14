# 0023. Modular monolith with four modules; split is a deploy change

Status: accepted, revised 2026-11-14 · Date: 2026-11-14

## Context
The brief suggested `services/{api,ingest,brain,builder,runtime}` "or fewer, justify". The first deployment serves a
tenant of one. Four services, an outbox and a load balancer for one user is cost with no benefit ([design review C (2026-11-14)](../SOURCES.md#design-review-c), P1(1)).

## Decision
- **One process, `offload serve`, runs four modules** until there is a second tenant. Each module keeps its own
  directory and entry point, so a split is a deploy change:
  - `services/api`: Hono HTTP edge. Public REST `/v1`, device ingest `/v1/ingest/*`, device commands, inbound webhooks
    `/v1/hooks/*`, auth; the Offload MCP server `/mcp` from M8.
  - `services/brain`: understanding, user model, opportunity finder, fix designer, model router.
  - `services/builder`: build orchestrator, sandbox provider, model egress proxy, verifier, receipts, reaper.
  - `services/runtime`: routine runtime, gate, item journal, device command queue, hs-1 measurement.
- **One exception**: `services/broker` runs as its own small process from day one, because it alone holds decrypt
  rights for credentials ([ADR 0034](0034-credential-broker-and-key-providers.md)). A process boundary is the only
  boundary that makes "models never touch credentials" true.
- **Ingest is a module of the API, not its own service.** It does no heavy work (validate, scan, insert, emit
  `observations.ingested`).
- Modules talk through Postgres: durable workflows and the `events_outbox` table ([API.md](../API.md#7-internal-events)).
  No message broker. In one process the outbox is still used, so the split changes nothing in code.
- Splitting into separate processes per module is an option at M8 (Pro), chosen when load or isolation needs it.

## Consequences
- One deploy unit plus the broker. Builder failures share the process with the API until the split; sandboxes run
  remotely, so the risk is bounded to orchestration code.

## Alternatives considered
- Four services from day one (the previous version): cost and moving parts with no benefit for a tenant of one.
- Five services: an ingest service with no distinct work.
- Broker inside the monolith: decrypt rights would belong to the whole process.

## Sources
Owner brief; [design review C (2026-11-14)](../SOURCES.md#design-review-c), P1(1), P1(3).

## Revisions
- 2026-11-14: modular monolith first, split at M8 if needed ([design review C (2026-11-14)](../SOURCES.md#design-review-c), P1(1)); broker as a separate process ([design review C (2026-11-14)](../SOURCES.md#design-review-c), P1(3)).
