import { AsyncLocalStorage } from "node:async_hooks";
import { randomUUID } from "node:crypto";
import { DBOS } from "@dbos-inc/dbos-sdk";
import { Pool, type PoolClient } from "pg";
import { cronMatches, parseCron, type CronSpec } from "./cron.ts";
import { withTenant } from "./tenant.ts";
import {
  DURABLE_SCHEMA,
  MAX_RECV_MS,
  SYSTEM_TENANT,
  assertDurableInput,
  assertIdsOnly,
  type DurableCreateOptions,
  type DurableInput,
  type DurableMessage,
  type DurableRuntime,
  type WorkflowInfo,
  type WorkflowState,
} from "./port.ts";

/** DBOS Transact implementation of the port (ADR 0009, option a: DBOS on Bun). One runtime per process. */

const APP_NAME = "offload";
const POLL_MS = 50;
/** A clock jump never replays more than a day of ticks. */
const MAX_CATCH_UP_MINUTES = 1440;

const tenantContext = new AsyncLocalStorage<{ tenantId: string }>();

function mapState(status: string): WorkflowState {
  if (status === "SUCCESS") return "success";
  if (status === "CANCELLED") return "cancelled";
  if (status === "ERROR" || status === "MAX_RECOVERY_ATTEMPTS_EXCEEDED") return "error";
  return "pending"; // PENDING, ENQUEUED, DELAYED
}

function statusesFor(state: WorkflowState): string[] {
  switch (state) {
    case "success": return ["SUCCESS"];
    case "cancelled": return ["CANCELLED"];
    case "error": return ["ERROR", "MAX_RECOVERY_ATTEMPTS_EXCEEDED"];
    case "pending": return ["PENDING", "ENQUEUED", "DELAYED"];
  }
}

function tenantOf(input: unknown[] | undefined): string | undefined {
  const first = input?.[0];
  if (typeof first === "object" && first !== null) {
    const t = (first as Record<string, unknown>)["tenant_id"];
    if (typeof t === "string") return t;
  }
  return undefined;
}

function toInfo(w: { workflowID: string; workflowName: string; status: string; input?: unknown[] | undefined; createdAt: number }): WorkflowInfo {
  return { workflowId: w.workflowID, name: w.workflowName, state: mapState(w.status), tenantId: tenantOf(w.input), createdAt: w.createdAt };
}

function roleOf(url: string): string | undefined {
  const user = decodeURIComponent(new URL(url).username);
  return user === "" ? undefined : user;
}

interface Schedule {
  cron: string;
  spec: CronSpec;
  name: string;
  lastMinute: number;
}

export async function createDurableRuntime(opts: DurableCreateOptions): Promise<DurableRuntime> {
  if (DBOS.isInitialized()) throw new Error("a DurableRuntime already exists in this process; call shutdown() first");
  const clock = opts.clock ?? { now: () => Date.now() };
  const pool = new Pool({ connectionString: opts.databaseUrl, max: 4 });
  const registered = new Map<string, (input: DurableInput) => Promise<void>>();
  const schedules = new Map<string, Schedule>();
  let polling = false;
  let closed = false;

  const runtime: DurableRuntime = {
    async startWorkflow(name, input, o) {
      const fn = registered.get(name);
      if (!fn) throw new Error(`unknown workflow "${name}"`);
      assertDurableInput(input);
      const workflowId = o?.workflowId ?? randomUUID();
      await DBOS.startWorkflow(fn, { workflowID: workflowId })(input);
      return { workflowId };
    },

    async step(name, fn) {
      if (!DBOS.isWithinWorkflow()) throw new Error("step() must be called inside a workflow");
      return DBOS.runStep(
        async () => {
          let out: Awaited<ReturnType<typeof fn>>;
          try {
            out = await fn();
          } catch (err) {
            // DBOS stores error text in schema durable, so only the step name and error class are kept.
            console.error(`durable: step "${name}" failed (${err instanceof Error ? err.name : "non-error"})`);
            throw new Error(`step "${name}" failed`);
          }
          assertIdsOnly(out, `step "${name}" output`); // content never reaches schema durable
          return out;
        },
        { name },
      );
    },

    async sleep(ms) {
      if (!DBOS.isWithinWorkflow()) throw new Error("sleep() must be called inside a workflow");
      await DBOS.sleep(ms);
    },

    async recv<T>(topic: string, timeoutMs: number) {
      if (timeoutMs > MAX_RECV_MS) {
        throw new Error(`recv timeout ${timeoutMs} ms is above MAX_RECV_MS ${MAX_RECV_MS} (15 minutes): end the workflow at a human wait instead`);
      }
      if (!DBOS.isWithinWorkflow()) throw new Error("recv() must be called inside a workflow");
      return DBOS.recv<T>(topic, { timeoutSeconds: timeoutMs / 1000 });
    },

    async send(workflowId: string, topic: string, msg: DurableMessage) {
      assertIdsOnly(msg, "message");
      await DBOS.send(workflowId, msg, topic);
    },

    async cancel(workflowId) {
      await DBOS.cancelWorkflow(workflowId);
    },

    async list(filter) {
      const rows = await DBOS.listWorkflows({
        loadInput: true,
        ...(filter.name ? { workflowName: filter.name } : {}),
        ...(filter.state ? { status: statusesFor(filter.state) as never } : {}),
      });
      return rows.map(toInfo);
    },

    async schedule(cron, name) {
      if (!registered.has(name)) throw new Error(`unknown workflow "${name}"`);
      const spec = parseCron(cron);
      schedules.set(`${name}|${cron}`, { cron, spec, name, lastMinute: Math.floor(clock.now() / 60_000) });
    },

    async purgeTenant(tenantId) {
      const mine = (await DBOS.listWorkflows({ loadInput: true })).filter((w) => tenantOf(w.input) === tenantId);
      if (mine.length === 0) return { workflowsDeleted: 0 };
      const ids = mine.map((w) => w.workflowID);
      const live = mine.filter((w) => mapState(w.status) === "pending").map((w) => w.workflowID);
      if (live.length > 0) await DBOS.cancelWorkflows(live);
      await DBOS.deleteWorkflows(ids, true);
      // Messages sent to these workflows go with them; delete any that outlived the cascade.
      await pool.query(`delete from ${DURABLE_SCHEMA}.notifications where destination_uuid = any($1::text[])`, [ids]);
      return { workflowsDeleted: ids.length };
    },

    async withTenant<T>(fn: (client: PoolClient) => Promise<T>) {
      const ctx = tenantContext.getStore();
      if (!ctx) throw new Error("withTenant() must be called inside a workflow");
      return withTenant(pool, ctx.tenantId, fn);
    },

    async shutdown() {
      if (closed) return;
      closed = true;
      clearInterval(timer);
      await DBOS.shutdown({ deregister: true });
      await pool.end();
    },
  };

  for (const [name, body] of Object.entries(opts.workflows)) {
    const wf = DBOS.registerWorkflow(
      async (input: DurableInput) => {
        assertDurableInput(input);
        try {
          await tenantContext.run({ tenantId: input.tenant_id }, () => body(runtime, input));
        } catch (err) {
          const msg = err instanceof Error ? err.message : "";
          // Our own errors carry no content; anything else is reduced to its class before DBOS stores it.
          if (/^(step ".{0,64}" (failed|output)|.{0,64}: (string|number|nested))/.test(msg)) throw err;
          console.error(`durable: workflow "${name}" failed (${err instanceof Error ? err.name : "non-error"})`);
          throw new Error(`workflow "${name}" failed`);
        }
      },
      { name },
    );
    registered.set(name, wf as unknown as (input: DurableInput) => Promise<void>);
  }

  try {
    if (opts.migratorUrl) {
      const applicationRole = roleOf(opts.databaseUrl);
      await DBOS.migrate(opts.migratorUrl, { schemaName: DURABLE_SCHEMA, ...(applicationRole ? { applicationRole } : {}) });
    }
    DBOS.setConfig({
      name: APP_NAME,
      systemDatabaseUrl: opts.databaseUrl,
      systemDatabaseSchemaName: DURABLE_SCHEMA,
      runMigrations: !opts.migratorUrl,
      logLevel: "error",
    });
    await DBOS.launch();
  } catch (err) {
    await DBOS.shutdown({ deregister: true }).catch(() => {});
    await pool.end().catch(() => {});
    throw err;
  }

  async function pollSchedules(): Promise<void> {
    if (polling || closed) return;
    polling = true;
    try {
      const nowMinute = Math.floor(clock.now() / 60_000);
      for (const s of schedules.values()) {
        const from = Math.max(s.lastMinute + 1, nowMinute - MAX_CATCH_UP_MINUTES + 1);
        try {
          for (let m = from; m <= nowMinute; m++) {
            if (!cronMatches(s.spec, m * 60_000)) continue;
            // Deterministic id (name, cron, minute): a tick never starts twice, across processes or restarts.
            await runtime.startWorkflow(
              s.name,
              { tenant_id: SYSTEM_TENANT, scheduled_for: new Date(m * 60_000).toISOString() },
              { workflowId: `sched:${s.name}:${s.cron.replace(/\s+/g, "_")}:${m * 60_000}` },
            );
          }
          s.lastMinute = Math.max(s.lastMinute, nowMinute);
        } catch (err) {
          // Retried on the next poll; one bad schedule does not stall the others.
          console.error(`durable: schedule "${s.name}" tick failed (${err instanceof Error ? err.name : "non-error"})`);
        }
      }
    } finally {
      polling = false;
    }
  }
  const timer = setInterval(() => void pollSchedules().catch(() => {}), POLL_MS);
  timer.unref();

  return runtime;
}
