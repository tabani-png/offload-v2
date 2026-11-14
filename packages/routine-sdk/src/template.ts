/** Stub (red). */
export class TemplateError extends Error {}
export type TemplateScope = { steps: Record<string, { output: unknown }>; item?: unknown };
export function renderArgs(_t: unknown, _s: TemplateScope): Record<string, unknown> {
  throw new Error("not implemented");
}
