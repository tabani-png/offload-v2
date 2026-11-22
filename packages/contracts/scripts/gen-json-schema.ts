/**
 * Writes packages/contracts/schemas/*.schema.json (JSON Schema Draft 2020-12) from the zod schemas.
 * Run: bun packages/contracts/scripts/gen-json-schema.ts. Output is committed; a test fails if it is stale.
 */
import { mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { z } from "zod";
import {
  ErrorEnvelopeSchema, FigureSchema, ForgetRequestSchema, ImportSchema, IngestEnvelopeSchema, IngestReceiptSchema,
  KeyframeMetaSchema, NoticeAckSchema, ObservationSchema, OpenImportRequestSchema, PurgeRequestStateSchema,
  ReviewEventSchema, StepResultSchema,
} from "../src/index.ts";

const SCHEMAS: Record<string, z.ZodType> = {
  "error-envelope": ErrorEnvelopeSchema,
  figure: FigureSchema,
  "forget-request": ForgetRequestSchema,
  import: ImportSchema,
  "ingest-envelope": IngestEnvelopeSchema,
  "ingest-receipt": IngestReceiptSchema,
  "keyframe-meta": KeyframeMetaSchema,
  "notice-ack": NoticeAckSchema,
  observation: ObservationSchema,
  "open-import-request": OpenImportRequestSchema,
  "purge-request-state": PurgeRequestStateSchema,
  "review-event": ReviewEventSchema,
  "step-result": StepResultSchema,
};

/**
 * zod refinements are not exported, so add the one rule JSON Schema can state: an object with `source` and
 * `import_id` needs `import_id` when `source` is "import".
 */
function addImportRule(node: unknown): void {
  if (Array.isArray(node)) return node.forEach(addImportRule);
  if (node === null || typeof node !== "object") return;
  const o = node as Record<string, unknown>;
  const props = o["properties"] as Record<string, unknown> | undefined;
  if (props && "source" in props && "import_id" in props) {
    o["if"] = { properties: { source: { const: "import" } }, required: ["source"] };
    o["then"] = { properties: { import_id: true }, required: ["import_id"] };
  }
  for (const v of Object.values(o)) addImportRule(v);
}

/** file name -> exact file text. Pure: no file access. */
export function generateSchemas(): Record<string, string> {
  const out: Record<string, string> = {};
  for (const [name, schema] of Object.entries(SCHEMAS)) {
    const json = z.toJSONSchema(schema, { target: "draft-2020-12", io: "input" }) as Record<string, unknown>;
    addImportRule(json);
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
