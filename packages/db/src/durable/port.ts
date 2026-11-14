/**
 * The DurableRuntime port (ADR 0009). Callers depend on this file only; the DBOS Transact implementation lives in
 * dbos-runtime.ts and can be swapped (fallback options in the ADR) without changing callers.
 *
 * Rules the port enforces in code:
 *  - ids only: workflow inputs, messages and step outputs hold uuids, ULIDs, hashes or enums, never content;
 *  - every workflow input has `tenant_id`;
 *  - workflows end at human waits: `recv` refuses a timeout above MAX_RECV_MS.
 */

export type Clock = { now(): number };

export type IdValue = string | number | boolean | null | IdValue[] | { [key: string]: IdValue };
/** A record of ids, hashes and enums. Checked at runtime by `assertIdsOnly`. */
export type DurableInput = { tenant_id: string } & Record<string, IdValue>;
export type DurableMessage = Record<string, IdValue>;

export type WorkflowState = "pending" | "success" | "error" | "cancelled";

export interface WorkflowInfo {
  workflowId: string;
  name: string;
  state: WorkflowState;
  /** `tenant_id` from the workflow input; undefined only for workflows started outside this port. */
  tenantId: string | undefined;
  createdAt: number;
}

/** The longest a workflow may wait in `recv`. Longer human waits end the workflow and a new one starts on the answer. */
export const MAX_RECV_MS = 900_000;

/** Postgres-schema owner for all durable state (ADR 0009). */
export const DURABLE_SCHEMA = "durable";

/** `tenant_id` used by scheduled workflows, which belong to no tenant. */
export const SYSTEM_TENANT = "system";

export type WorkflowFn = (rt: DurableRuntime, input: DurableInput) => Promise<void>;

export interface DurableRuntime {
  startWorkflow<I extends DurableInput>(name: string, input: I, opts?: { workflowId?: string }): Promise<{ workflowId: string }>;
  /** Checkpointed. Replays the stored result after a restart instead of running `fn` again. Workflow code only. */
  step<T>(name: string, fn: () => Promise<T>): Promise<T>;
  /** Durable sleep (real time; the injected clock drives schedules only). Workflow code only. */
  sleep(ms: number): Promise<void>;
  /** Workflow code only. Throws when `timeoutMs` is above MAX_RECV_MS. */
  recv<T>(topic: string, timeoutMs: number): Promise<T | null>;
  send(workflowId: string, topic: string, msg: DurableMessage): Promise<void>;
  cancel(workflowId: string): Promise<void>;
  list(filter: { name?: string; state?: WorkflowState }): Promise<WorkflowInfo[]>;
  /** 5-field cron, UTC. Re-declare on every boot. At most once per tick (deterministic ids), but ticks due while the process was down are not replayed. */
  schedule(cron: string, name: string): Promise<void>;
  purgeTenant(tenantId: string): Promise<{ workflowsDeleted: number }>;
  /**
   * Run `fn` in a transaction with `app.tenant_id` set to this workflow's `tenant_id` (set_config, transaction-local).
   * Workflow code only. No network I/O inside `fn`. m1-03 replaces the helper behind it.
   */
  withTenant<T>(fn: (client: import("pg").PoolClient) => Promise<T>): Promise<T>;
  shutdown(): Promise<void>;
}

export interface DurableCreateOptions {
  /** Connection for the runtime role. */
  databaseUrl: string;
  /** Connection for `offload_migrator`. When set it runs the migrations and owns schema `durable`. */
  migratorUrl?: string;
  clock?: Clock;
  /** Workflow bodies by name. Must be the same set on every process that can recover the workflow. */
  workflows: Record<string, WorkflowFn>;
}

const MAX_ID_LENGTH = 64;
const MAX_DEPTH = 6;

/** Throws unless `value` is made only of short, whitespace-free strings, numbers, booleans, null, and arrays/records of those. */
export function assertIdsOnly(value: unknown, path = "value", depth = 0): void {
  if (depth > MAX_DEPTH) throw new Error(`${path}: nested too deeply for an ids-only value`);
  if (value === null || value === undefined || typeof value === "boolean") return;
  if (typeof value === "number") {
    if (!Number.isFinite(value)) throw new Error(`${path}: number is not finite`);
    return;
  }
  if (typeof value === "string") {
    if (value.length > MAX_ID_LENGTH) throw new Error(`${path}: string longer than ${MAX_ID_LENGTH} characters is not an id`);
    if (/\s/.test(value)) throw new Error(`${path}: string with whitespace is not an id`);
    return;
  }
  if (Array.isArray(value)) {
    value.forEach((v, i) => assertIdsOnly(v, `${path}[${i}]`, depth + 1));
    return;
  }
  if (typeof value === "object") {
    for (const [k, v] of Object.entries(value as Record<string, unknown>)) {
      assertIdsOnly(k, `${path} key`, depth + 1); // keys are serialised too
      assertIdsOnly(v, `${path}.${k.slice(0, 16)}`, depth + 1);
    }
    return;
  }
  throw new Error(`${path}: ${typeof value} is not allowed in durable state`);
}

export function assertDurableInput(input: unknown): asserts input is DurableInput {
  if (typeof input !== "object" || input === null || Array.isArray(input)) throw new Error("workflow input must be a record");
  const tenant = (input as Record<string, unknown>)["tenant_id"];
  if (typeof tenant !== "string" || tenant.length === 0) throw new Error("workflow input must include tenant_id");
  assertIdsOnly(input, "input");
}
