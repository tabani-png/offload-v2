---
id: m1-01-durable-spike
title: Durable runtime spike - DBOS Transact on Bun behind the DurableRuntime port, with the fallback order and the outcome written into ADR 0009
milestone: M1
status: in_progress
depends_on: []
parallel_safe: false
human_gated: false
model_tier: sonnet
size: M
parallel_group: M1-A
owns: [packages/db/**, packages/testkit/**, infra/docker-compose/**, docs/adr/0009-durable-execution-on-postgres.md]
verify: bash slices/m1-01-durable-spike/verify.sh
min_tests: 8
paths_in_scope: [packages/db/**, packages/testkit/**, slices/m1-01-durable-spike/**, docs/adr/0009-durable-execution-on-postgres.md, infra/docker-compose/**, package.json, bun.lock]
paths_out_of_scope: [ee/**, apps/**, services/**, packages/contracts/**, docs/ARCHITECTURE.md, docs/API.md]
red_tests: [DURABLE]
---

# m1-01-durable-spike

## Summary
The first slice of [M1](../../docs/ROADMAP.md#m1-foundations). Time box: one working day. It answers one question
before anything is built on it: does DBOS Transact for TypeScript run on Bun? It implements the `DurableRuntime` port
from [ADR 0009](../../docs/adr/0009-durable-execution-on-postgres.md) and writes the result into that ADR's
"Spike result" section. Builds ([ARCHITECTURE section 8](../../docs/ARCHITECTURE.md#8-build-orchestrator)) and
routine runs ([section 11](../../docs/ARCHITECTURE.md#11-routine-runtime)) depend on it.

## Contract
- Delete `packages/db/tests/smoke.test.ts` (the TODO marker is replaced).
- Dependencies (exact pins, added to `packages/db/package.json`): `@dbos-inc/dbos-sdk` (option a/b), `pg` (driver used
  by the port's Postgres helpers). Option c adds `graphile-worker` instead of DBOS. Nothing else.
- Port, in `packages/db/src/durable/port.ts`:
  ```ts
  interface DurableRuntime {
    startWorkflow<I extends DurableInput>(name: string, input: I): Promise<{ workflowId: string }>;
    step<T>(name: string, fn: () => Promise<T>): Promise<T>;      // checkpointed; replays the stored result
    sleep(ms: number): Promise<void>;
    recv<T>(topic: string, timeoutMs: number): Promise<T | null>;
    send(workflowId: string, topic: string, msg: DurableMessage): Promise<void>;
    cancel(workflowId: string): Promise<void>;
    list(filter: { name?: string; state?: "pending" | "success" | "error" | "cancelled" }): Promise<WorkflowInfo[]>;
    schedule(cron: string, name: string): Promise<void>;           // 5-field cron, UTC
    purgeTenant(tenantId: string): Promise<{ workflowsDeleted: number }>;
  }
  DurableRuntime.create({ databaseUrl, clock?: Clock }): Promise<DurableRuntime>  // Clock = { now(): number }; tests inject a fake
  ```
- **Ids only**: `DurableInput` and `DurableMessage` are records whose values are uuids, ULIDs, hashes (64 hex) or
  enums. A runtime check (`assertIdsOnly`) rejects strings longer than 64 characters or containing whitespace, so no
  content (text, titles, tool output) is ever serialised into schema `durable`. Every input has `tenant_id`.
- **Workflows end at human waits**: there is no `recv` with a timeout longer than 15 minutes in product code. A
  workflow that needs a human answer writes its state to tenant tables and ends; the answer starts a new workflow.
  The port exposes `MAX_RECV_MS = 900_000` and `recv` throws above it.
- State lives in schema `durable`, owned by `offload_migrator`. `purgeTenant` deletes every workflow, step and
  message row whose input `tenant_id` matches (called by tenant wipe and forget-all).
- **Fallback order** (try in order; stop at the first that passes every test below):
  (a) DBOS Transact on Bun for every module;
  (b) DBOS Transact on Node 22 for the builder and runtime modules only, Bun for api and brain (same TypeScript; the
  test runner for the DURABLE suite becomes `node --test` via a script, recorded under "Scope changes");
  (c) `graphile-worker` plus our own step journal table `durable.steps (workflow_id, step_no, name, result_json,
  completed_at)` behind the same port.
- Output: the "Spike result" section of ADR 0009 is filled in by this slice: chosen option, versions, what failed for
  any option skipped, and the date.
- Tests need a real Postgres 17 (`DATABASE_URL`; `infra/docker-compose` provides one; CI core job has a service).
  PGlite is not acceptable here.

## Red tests (write first, run, see them fail)
Folder: `packages/db/tests/m1-01-durable-spike/`.

| Tag | Test name | Asserts |
|---|---|---|
| DURABLE | DURABLE: a two-step workflow killed between steps resumes once on Bun | a child `Bun.spawn` process runs the workflow; the parent waits until step 1's checkpoint row exists, sends SIGKILL, restarts; step 1 ran once, step 2 ran once |
| DURABLE | DURABLE: a completed step is not re-run after restart | step counter file shows 1 |
| DURABLE | DURABLE: workflow input carries tenant_id and steps run inside withTenant | input without `tenant_id` is rejected; a step reads `current_setting('app.tenant_id')` equal to the input |
| DURABLE | DURABLE: workflow inputs and messages hold ids only | `assertIdsOnly` rejects a 65-char string and a string with a space; schema `durable` holds no fixture canary text after a run |
| DURABLE | DURABLE: recv longer than 15 minutes is refused | `recv(topic, 900_001)` throws; workflows end at human waits |
| DURABLE | DURABLE: a scheduled workflow fires on its cron in a fake clock | fake clock advanced past `*/5 * * * *` fires exactly once per tick |
| DURABLE | DURABLE: cancel stops a sleeping workflow before its next step | |
| DURABLE | DURABLE: purgeTenant removes every durable row of that tenant and no other | two tenants; counts before and after |

## Out of scope
Tenancy tables (m1-03; `withTenant` here is a minimal helper that m1-03 replaces), any real build or routine
workflow, queues with concurrency limits (added with the first builder slice).

## Verify
`bash slices/m1-01-durable-spike/verify.sh` (needs `DATABASE_URL`).

## Scope changes
None yet. Record the chosen fallback option here if (a) fails.
