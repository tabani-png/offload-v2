/**
 * Child process for the kill test. Run with: bun child-workflow.ts <start|resume> <dir> <workflowId>
 *   start:  create the runtime, start the two-step workflow, keep running (the parent kills it with SIGKILL).
 *   resume: create the runtime (DBOS recovers the pending workflow), wait for it to finish, exit 0.
 */
import { join } from "node:path";
import { DurableRuntime, type WorkflowFn } from "../../src/durable/index.ts";
import { bump, databaseUrl, waitFor } from "./helpers.ts";

const [mode, dir, workflowId] = process.argv.slice(2);
if (!mode || !dir || !workflowId) throw new Error("usage: child-workflow.ts <start|resume> <dir> <workflowId>");

const twoStep: WorkflowFn = async (rt) => {
  await rt.step("step-one", async () => {
    bump(join(dir, "step1.count"));
  });
  await rt.step("step-two", async () => {
    // Held here until the parent releases it, so the SIGKILL lands between step 1's checkpoint and step 2's.
    await waitFor("release", async () => (await Bun.file(join(dir, "release")).exists()) || null, 60_000);
    bump(join(dir, "step2.count"));
  });
};

const rt = await DurableRuntime.create({ databaseUrl: databaseUrl(), workflows: { "two-step": twoStep } });
if (mode === "start") {
  // The parent checks this pid is gone after SIGKILL: a launcher in between (a shell shim for `bun`) would take the
  // signal and leave this process running and holding database connections and locks.
  await Bun.write(join(dir, "start.pid"), String(process.pid));
  await rt.startWorkflow("two-step", { tenant_id: "0197a000-0000-7000-8000-00000000000a" }, { workflowId });
  await new Promise(() => {}); // wait to be killed
} else {
  await waitFor("workflow success", async () => (await rt.list({ name: "two-step", state: "success" })).some((w) => w.workflowId === workflowId));
  await rt.shutdown();
  process.exit(0);
}
