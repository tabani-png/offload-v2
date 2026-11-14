import { createDurableRuntime } from "./dbos-runtime.ts";
import type { DurableCreateOptions, DurableRuntime as DurableRuntimePort } from "./port.ts";

export * from "./port.ts";
export { withTenant } from "./tenant.ts";
export { parseCron, cronMatches } from "./cron.ts";

/** `DurableRuntime.create({ databaseUrl, clock?, workflows })`: the port type plus its factory, under one name. */
export type DurableRuntime = DurableRuntimePort;
export const DurableRuntime = {
  create: (opts: DurableCreateOptions): Promise<DurableRuntime> => createDurableRuntime(opts),
};
