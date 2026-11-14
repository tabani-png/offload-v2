# 0009. Durable execution on Postgres (DBOS Transact behind a port)

Status: accepted, with a compatibility spike in M1 · Date: 2026-11-14

## Context
Builds and routine runs are long, multi-step and must survive restarts without repeating side effects. Criterion from
the owner's brief: **self-host with only Postgres**.

## Decision
- Use **DBOS Transact for TypeScript** (MIT license, workflows and steps checkpointed in Postgres, no separate server)
  behind a `DurableRuntime` port in `packages/db` (`startWorkflow`, `step`, `sleep`, `recv`/`send`, `cancel`, `list`).
- Workflow state lives in its own Postgres schema `durable`, owned by the migrator role. Tenant id is a workflow input
  and every step that touches tenant tables runs inside `withTenant` ([ADR 0013](0013-tenancy-and-rls.md)).
- Side effects are not made idempotent by the library alone. The **item journal** ([ADR 0004](0004-every-external-action-is-gated.md))
  is the source of truth for commits: a step that finds an item in `sending` or `unknown` after a restart marks it
  `unknown` and never re-sends.
- Schedules (cron), queues with concurrency limits, and timers come from the same library.
- **M1 spike (slice `m1-02-tenancy-rls` acceptance includes it):** DBOS is documented for Node.js. Bun support is not
  confirmed. The spike runs a two-step workflow, kills the process between steps, and checks it resumes once. If it
  fails on Bun, the fallback is **graphile-worker** (MIT, Postgres-only job queue) plus our own step journal table
  `durable.steps`, behind the same port. The port means no caller changes.

## Consequences
- No Temporal cluster, no Redis. Backups cover workflow state.
- Throughput is bounded by Postgres. Fine for a tenant of one and small teams; measure before Enterprise scale.

## Alternatives considered
| Option | License | Self-host needs | Why not |
|---|---|---|---|
| Temporal | MIT (server and SDKs) | Temporal server cluster + its DB | Heavy to self-host; a second system to run |
| Inngest | Server source-available (SSPL-style with delayed open release) | Inngest server | License and an extra server |
| Restate | BSL 1.1 for the server | Restate server | License and an extra server |
| pg-boss | MIT | Postgres | Queue only; we would build steps ourselves (kept as an option) |
| graphile-worker | MIT | Postgres | Queue only; chosen fallback |
| DBOS Transact | MIT | Postgres | **Chosen.** Bun support unverified, hence the spike |

License facts above were checked on 2026-11-14 for DBOS (MIT). Inngest and Restate terms should be re-checked before
anyone cites them externally.

## Sources
Owner brief ("self-host with only Postgres"); dbos-inc/dbos-transact-ts repository metadata (MIT).
