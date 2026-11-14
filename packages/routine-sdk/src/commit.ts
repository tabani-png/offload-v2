import { jcs, sha256Hex } from "@offload/contracts";
import type { ResolvedStep, RoutineStep } from "./routine.ts";
import { TemplateError, renderArgs, type TemplateScope } from "./template.ts";

/**
 * One commit item (ADR 0026: commit steps return items, they never call out). The runtime collects items into a
 * batch, journals them and the gate decides; the SDK has no function that performs I/O.
 * item_hash = sha256Hex(JCS({ capability, connection_ref, args })).
 * item_key = "<step id>/" + sha256Hex(JCS(foreach item)), or of the rendered args when the step has no foreach, so the
 * same input gives the same key in every run (the runtime dedupes on it through item_journal.item_ref).
 */
export type Item = {
  item_key: string;
  item_hash: string;
  capability: string;
  connection_ref: string;
  args: Record<string, unknown>;
};

export function itemHash(item: Pick<Item, "capability" | "connection_ref" | "args">): string {
  return sha256Hex(jcs({ capability: item.capability, connection_ref: item.connection_ref, args: item.args }));
}

/** The items a commit step returns for this scope. Pure. Throws TemplateError on a bad scope or a non-commit step. */
export function planCommit(step: RoutineStep | ResolvedStep, scope: TemplateScope): Item[] {
  if (step.class !== "commit") throw new TemplateError(`planCommit needs a commit step, step ${step.id} is ${step.class}`);
  const { capability, connection_ref } = step;
  if (capability === undefined) throw new TemplateError(`step ${step.id} has no capability`);
  const make = (args: Record<string, unknown>, keyOf: unknown): Item => {
    const fields = { capability, connection_ref, args };
    return { item_key: `${step.id}/${sha256Hex(jcs(keyOf))}`, item_hash: itemHash(fields), ...fields };
  };
  if (step.foreach === undefined) {
    const args = renderArgs(step.args, { steps: scope.steps });
    return [make(args, args)];
  }
  if (!Object.hasOwn(scope.steps, step.foreach)) throw new TemplateError(`no output for step ${step.foreach}`);
  const list = scope.steps[step.foreach]?.output;
  if (!Array.isArray(list)) throw new TemplateError(`foreach step ${step.foreach} did not return a list`);
  return list.map((item: unknown) => make(renderArgs(step.args, { steps: scope.steps, item }), item));
}
