import type { JsonSchema } from "./types.ts";

/**
 * Labels instead of numbers (ADR 0003). A schema passed to the router may hold only enum labels, booleans, objects and
 * arrays of those; a string without an enum is allowed only where the schema marks it `x-offload-text` (names or text
 * fields). Code maps labels to numbers with `mapLabel` and a table next to the caller.
 */

export class LabelSchemaError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "LabelSchemaError";
  }
}

export class UnknownLabelError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "UnknownLabelError";
  }
}

const TEXT_MARK = "x-offload-text";

function isObj(v: unknown): v is Record<string, unknown> {
  return typeof v === "object" && v !== null && !Array.isArray(v);
}

function check(node: unknown, path: string): void {
  if (!isObj(node)) throw new LabelSchemaError(`${path}: schema must be an object`);
  const type = node["type"];
  if (typeof type !== "string") throw new LabelSchemaError(`${path}: needs exactly one type`);
  for (const k of ["anyOf", "oneOf", "allOf", "not", "$ref", "patternProperties"]) {
    if (k in node) throw new LabelSchemaError(`${path}: ${k} is not allowed`);
  }
  switch (type) {
    case "object": {
      const props = node["properties"];
      if (props !== undefined && !isObj(props)) throw new LabelSchemaError(`${path}: properties must be an object`);
      const ap = node["additionalProperties"];
      if (ap !== undefined && ap !== false) throw new LabelSchemaError(`${path}: additionalProperties must be false`);
      for (const [k, v] of Object.entries(props ?? {})) check(v, `${path}.${k}`);
      return;
    }
    case "array":
      check(node["items"], `${path}[]`);
      return;
    case "boolean":
      return;
    case "string": {
      const e = node["enum"];
      if (Array.isArray(e) && e.length > 0 && e.every((x) => typeof x === "string")) return;
      if (node[TEXT_MARK] === true) return;
      throw new LabelSchemaError(`${path}: a string must be an enum of labels or marked ${TEXT_MARK}`);
    }
    default:
      throw new LabelSchemaError(`${path}: type ${type} is not allowed (labels only, numbers come from code)`);
  }
}

/** Throws LabelSchemaError unless the schema is label-only. */
export function assertLabelSchema(schema: JsonSchema): void {
  check(schema, "$");
}

/** Validates a parsed model output against a label-only schema. */
export function validateLabelOutput(schema: JsonSchema, value: unknown): boolean {
  const type = schema["type"];
  switch (type) {
    case "object": {
      if (!isObj(value)) return false;
      const props = (schema["properties"] ?? {}) as Record<string, JsonSchema>;
      const required = Array.isArray(schema["required"]) ? (schema["required"] as string[]) : [];
      for (const r of required) if (!Object.hasOwn(value, r)) return false;
      for (const [k, v] of Object.entries(value)) {
        const p = Object.hasOwn(props, k) ? props[k] : undefined;
        if (!p) {
          if (schema["additionalProperties"] === false) return false;
          continue;
        }
        if (!validateLabelOutput(p, v)) return false;
      }
      return true;
    }
    case "array":
      return Array.isArray(value) && value.every((v) => validateLabelOutput(schema["items"] as JsonSchema, v));
    case "boolean":
      return typeof value === "boolean";
    case "string": {
      if (typeof value !== "string") return false;
      const e = schema["enum"];
      return Array.isArray(e) ? e.includes(value) : schema[TEXT_MARK] === true;
    }
    default:
      return false;
  }
}

/** Maps a label to its number. An unknown label throws. */
export function mapLabel<L extends string>(table: Readonly<Record<L, number>>, label: string): number {
  if (!Object.hasOwn(table, label)) throw new UnknownLabelError(`unknown label`);
  return (table as Record<string, number>)[label]!;
}
