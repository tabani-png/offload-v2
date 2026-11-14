import type { JsonSchema } from "./types.ts";

export class LabelSchemaError extends Error {}
export class UnknownLabelError extends Error {}

export function assertLabelSchema(_schema: JsonSchema): void {
  throw new Error("not implemented");
}

export function validateLabelOutput(_schema: JsonSchema, _value: unknown): boolean {
  throw new Error("not implemented");
}

export function mapLabel<L extends string>(_table: Readonly<Record<L, number>>, _label: string): number {
  throw new Error("not implemented");
}
