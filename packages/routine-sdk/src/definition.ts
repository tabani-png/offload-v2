import type { ResolvedRoutineDefinition, RoutineDefinition } from "./routine.ts";
/** Stub (red). */
export type PinnedTool = { capability: string; tool_name: string; tool_pin_hash: string };
export type PinnedConnection = { connection_ref: string; connection_id: string; adapter: string; provider: string; account_label: string; tools: PinnedTool[] };
export type Brief = { capabilities: string[]; connections: PinnedConnection[] };
export class ResolveError extends Error {}
export class ManifestError extends Error {
  readonly code: string = "";
}
export function resolveDefinition(_d: RoutineDefinition, _p: PinnedConnection[]): ResolvedRoutineDefinition {
  throw new Error("not implemented");
}
export function definitionHash(_r: ResolvedRoutineDefinition): string {
  throw new Error("not implemented");
}
export function describeDefinition(_r: ResolvedRoutineDefinition): string[] {
  throw new Error("not implemented");
}
export function checkManifest(_d: RoutineDefinition, _b: Brief): void {
  throw new Error("not implemented");
}
