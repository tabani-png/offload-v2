import type { TemplateScope } from "./template.ts";
/** Stub (red). */
export type Item = { item_key: string; item_hash: string; capability: string; connection_ref: string; args: Record<string, unknown> };
export function planCommit(_step: unknown, _scope: TemplateScope): Item[] {
  throw new Error("not implemented");
}
