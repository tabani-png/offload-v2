# 0009. Durable execution on Postgres (DBOS Transact behind a port)

Status: accepted, revised 2026-11-14; spike passed on option 1 (DBOS on Bun) 2026-11-14 · Date: 2026-11-14

## Context
Builds and routine runs are long, multi-step and must survive restarts without repeating side effects. Criterion from
the owner's brief: **self-host with only Postgres**. DBOS is documented for Node.js; Bun support is unverified.

## Decision
- Use **DBOS Transact for TypeScript** (MIT license, workflows and steps checkpointed in Postgres, no separate server)
  behind a `DurableRuntime` port in `packages/db`:
  `startWorkflow(name, input) → handle`, `step(name, fn)`, `sleep(ms)`, `recv(topic, timeoutMs)`,
  `send(workflowId, topic, msg)`, `cancel(id)`, `list(filter)`, `schedule(cron, name)`, created with
  `DurableRuntime.create({ clock })` so tests inject a fake clock.
- **Workflows end at every human wait.** A run that needs a batch approval, a build that needs OK or deploy, and a run
  waiting for the Mac (`awaiting_device`) end their workflow. The answer (approve, reject, device result) starts a new
  workflow that reads state from `runs`, `batches`, `item_journal` and `builds`. No workflow is held open for hours
  across deploys, so pinned code versions never block an upgrade.
- **The durable schema holds ids only.** Workflow inputs, step inputs and step outputs are ids and hashes (tenant id,
  run id, build id, item id), never content. A test fails if a step output contains text from a content fixture.
  Rows for a tenant are purged on forget-all and tenant wipe.
- Workflow state lives in its own Postgres schema `durable`, owned by the migrator role. Tenant id is a workflow input
  and every step that touches tenant tables runs inside `withTenant` ([ADR 0013](0013-tenancy-and-rls.md)), with no
  network I/O inside that transaction.
- Side effects are not made idempotent by the library alone. The **item journal** ([ADR 0004](0004-every-external-action-is-gated.md))
  is the source of truth for commits: a step that finds an item in `sending` or `unknown` after a restart marks it
  `unknown` and never re-sends.
- Schedules (cron), queues with concurrency limits, and timers come from the same library.
- **Spike first, as its own slice** (`m1-01-durable-spike`, one day, before any other M1 slice). It runs a two-step
  workflow in a child process, kills it with SIGKILL after step 1's checkpoint is observed, restarts, and checks each
  step ran once; plus a cron schedule under a fake clock. Fallback order if it fails:
  1. DBOS on Bun (the plan);
  2. DBOS on **Node 22 for the builder and runtime modules only**, Bun for api and brain: same TypeScript, the runtime
     DBOS documents, no design change;
  3. **graphile-worker** (MIT, Postgres-only queue) plus our own step journal `durable.steps`, behind the same port.
     Because workflows end at human waits, this option needs little more than the journal.
- The spike writes its outcome into this ADR under "Spike result".

## Spike result
Slice `m1-01-durable-spike`, run 2026-11-14.

- **Chosen: option 1, DBOS Transact on Bun, for every module.** Options 2 and 3 were not needed and were not tried.
- Versions: `@dbos-inc/dbos-sdk` 5.5.0, `pg` 8.23.1, Bun 1.4.4, Postgres 17.11. Real Postgres, no PGlite.
- What the tests show on Bun: a two-step workflow run in a child `Bun.spawn` process is killed with SIGKILL after step
  1's checkpoint row exists in `durable.operation_outputs`; the restarted child recovers the pending workflow, step 1
  does not run again and step 2 runs once. Cancel stops a sleeping workflow before its next step. `purgeTenant` removes
  every workflow, step and message row of one tenant and leaves the other tenant's rows.
- State lives in schema `durable` (`systemDatabaseSchemaName`), inside the one application database, not DBOS's default
  separate `<app>_dbos_sys` database. When `migratorUrl` is given, `DBOS.migrate` runs as `offload_migrator`, which
  owns the schema, and the runtime role gets grants; the runtime then starts with `runMigrations: false`.
- Port details the spike settled:
  - `DurableRuntime.create({ databaseUrl, migratorUrl?, clock?, workflows })` takes the workflow bodies by name. DBOS
    is a process-wide singleton, so one runtime per process; `shutdown()` deregisters so tests can create another.
  - **Schedules use our own tick loop, not DBOS's scheduler**, because DBOS schedules read the real clock and the
    port must run under a fake one. A tick starts workflow `name` with the deterministic id `sched:<name>:<minute ms>`
    and input `{ tenant_id: "system", scheduled_for }`, so a tick never starts twice across restarts or processes (at most once: ticks due while every process was down
    are not replayed). Schedules are held in memory: the caller declares them on every boot. A clock jump replays at most 1440 minutes.
  - Error text from steps and workflow bodies is reduced to the step or workflow name before DBOS stores it, and object
    keys are checked like values, so no content reaches `durable` through errors or keys.
  - `purgeTenant` lists then deletes; callers must stop new starts for the tenant first.
  - Step outputs go through `assertIdsOnly` as well as inputs and messages; a step that returns text fails the
    workflow instead of writing the text into `durable`.
  - `sleep` is DBOS's durable sleep on real time. `recv` takes a timeout up to `MAX_RECV_MS` (900 000 ms).
  - `withTenant` here is the minimal helper that m1-03 replaces.
- Not covered by the spike, to measure later: throughput, queues with concurrency limits (first builder slice), and
  DBOS application-version pinning across deploys (workflows end at human waits, so old versions drain quickly).

## Consequences
- No Temporal cluster, no Redis. Backups cover workflow state.
- Throughput is bounded by Postgres. Fine for a tenant of one and small teams; measure before Enterprise scale.
- Option 2 would have meant two runtimes in one repo; it was not needed. The port still keeps callers unchanged if DBOS
  ever has to be swapped.

## Alternatives considered
| Option | License | Self-host needs | Why not |
|---|---|---|---|
| Temporal | MIT (server and SDKs) | Temporal server cluster + its DB | Heavy to self-host; a second system to run |
| Inngest | Server source-available (SSPL-style with delayed open release) | Inngest server | License and an extra server |
| Restate | BSL 1.1 for the server | Restate server | License and an extra server |
| pg-boss | MIT | Postgres | Queue only; we would build steps ourselves |
| graphile-worker | MIT | Postgres | Queue only; fallback 3 |
| DBOS Transact | MIT | Postgres | **Chosen.** Bun support unverified, hence the spike |

License facts above were checked on 2026-11-14 for DBOS (MIT). Inngest and Restate terms should be re-checked before
anyone cites them externally.

## Sources
Owner brief ("self-host with only Postgres"); dbos-inc/dbos-transact-ts repository metadata (MIT).

## Revisions
- 2026-11-14: spike moved to its own first slice with a written outcome; fallback order DBOS-Bun → DBOS-Node for
  builder/runtime → graphile-worker; workflows end at human waits; ids-only durable state with purge; port signature
  and kill method spelled out ([design review C (2026-11-14)](../SOURCES.md#design-review-c), P1(4), [design review A (2026-11-14)](../SOURCES.md#design-review-a), #34, #118).
- 2026-11-14: spike result written by m1-01-durable-spike: DBOS on Bun passes, option 1 chosen; schedules use our own
  tick loop for fake-clock tests.
