/**
 * Writes packages/routine-sdk/schemas/*.schema.json (JSON Schema Draft 2020-12) from the zod schemas.
 * Run: bun packages/routine-sdk/scripts/gen-json-schema.ts. Output is committed; a test fails if it is stale.
 * Cross-step rules are zod refinements and are not in the JSON Schema (see src/routine.ts).
 */
import { mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { z } from "zod";
import { ResolvedRoutineDefinitionSchema, RoutineDefinitionSchema } from "../src/routine.ts";

const SCHEMAS: Record<string, z.ZodType> = {
  routine: RoutineDefinitionSchema,
  "resolved-routine": ResolvedRoutineDefinitionSchema,
};

/** file name -> exact file text. Pure: no file access. */
export function generateSchemas(): Record<string, string> {
  const out: Record<string, string> = {};
  for (const [name, schema] of Object.entries(SCHEMAS)) {
    const json = z.toJSONSchema(schema, { target: "draft-2020-12", io: "input" }) as Record<string, unknown>;
    const { $schema, ...rest } = json;
    const doc = { $schema, $id: `https://offload.consultance.ai/schemas/${name}.json`, ...rest };
    out[`${name}.schema.json`] = `${JSON.stringify(doc, null, 2)}\n`;
  }
  return out;
}

if (import.meta.main) {
  const dir = join(import.meta.dir, "../schemas");
  mkdirSync(dir, { recursive: true });
  for (const [file, text] of Object.entries(generateSchemas())) writeFileSync(join(dir, file), text);
}
