import { createHash } from "node:crypto";
import { expect, test } from "bun:test";
import type { ToolPin } from "@offload/contracts/src/connections/index.ts";
import { normalizeTools } from "../../src/adapters.ts";
import { comparePins, PinExistsError, recordPins, toolPinHash, type SqlTx } from "../../src/pins.ts";
import type { RawTool } from "../../src/broker-port.ts";
import type { NormalizedTool } from "../../src/port.ts";

/** Fixed vector: the RFC 8785 canonical JSON (keys sorted, no whitespace) of the three hashed fields, by hand. */
const VECTOR_TOOL: NormalizedTool = {
  name: "sheet_append_row",
  description: "Append one row to a sheet.",
  input_schema: {
    type: "object",
    required: ["row"],
    properties: { row: { type: "array", items: { type: "string" } } },
  },
};
const VECTOR_CANONICAL =
  '{"description":"Append one row to a sheet.","input_schema":{"properties":{"row":{"items":{"type":"string"},"type":"array"}},"required":["row"],"type":"object"},"name":"sheet_append_row"}';
const VECTOR_HASH = "8228e745f3d6a89fb3aa3e08e8392468590a2669c2ad25e0440815ed5c875327";

function tool(name: string, description = `Does ${name}.`): NormalizedTool {
  return { name, description, input_schema: { type: "object", properties: {}, additionalProperties: false } };
}

function pinsOf(tools: NormalizedTool[]): ToolPin[] {
  return tools.map((t) => ({ name: t.name, pin_hash: toolPinHash(t) }));
}

test("PIN: toolPinHash is sha256 of the JCS of name, description and input_schema", () => {
  expect(createHash("sha256").update(VECTOR_CANONICAL, "utf8").digest("hex")).toBe(VECTOR_HASH);
  expect(toolPinHash(VECTOR_TOOL)).toBe(VECTOR_HASH);

  // Extra keys on the input are ignored.
  const withExtras = {
    ...VECTOR_TOOL,
    title: "Append row",
    outputSchema: { type: "object" },
    _meta: { source: "example.test" },
  } as NormalizedTool;
  expect(toolPinHash(withExtras)).toBe(VECTOR_HASH);

  // Each hashed field matters.
  expect(toolPinHash({ ...VECTOR_TOOL, name: "sheet_append_rows" })).not.toBe(VECTOR_HASH);
  expect(toolPinHash({ ...VECTOR_TOOL, description: "Append one row to a sheet" })).not.toBe(VECTOR_HASH);
  expect(toolPinHash({ ...VECTOR_TOOL, input_schema: { type: "object" } })).not.toBe(VECTOR_HASH);
});

test("PIN: changing readOnlyHint or any other annotation does not change the pin hash", () => {
  const base = { name: "issue_list", description: "List issues.", inputSchema: { type: "object", properties: {} } };
  const raws: RawTool[][] = [
    [{ ...base }],
    [{ ...base, annotations: { readOnlyHint: true } }],
    [{ ...base, annotations: { readOnlyHint: false, destructiveHint: true } }],
    [{ ...base, annotations: { readOnlyHint: true, idempotentHint: true, openWorldHint: false, title: "Issues" } }],
  ];
  const hashes = raws.map((r) => {
    const normalized = normalizeTools(r);
    expect(normalized).toHaveLength(1);
    expect(Object.keys(normalized[0] as NormalizedTool).sort()).toEqual(["description", "input_schema", "name"]);
    return toolPinHash(normalized[0] as NormalizedTool);
  });
  expect(new Set(hashes).size).toBe(1);

  // An annotations key passed straight to toolPinHash is ignored too.
  const plain = normalizeTools([{ ...base }])[0] as NormalizedTool;
  const annotated = { ...plain, annotations: { readOnlyHint: false, destructiveHint: true } } as NormalizedTool;
  expect(toolPinHash(annotated)).toBe(toolPinHash(plain));
});

test("PIN: normalizeTools keeps name, description and input_schema with defaults and drops invalid tools", () => {
  const out = normalizeTools([
    { name: "page_read", inputSchema: { type: "object", properties: { id: { type: "string" } } } },
    { name: "page_create", description: "Create a page.", input_schema: { type: "object" } },
    { name: "no_schema", description: "No schema." },
    { name: "bad name with spaces", description: "x", input_schema: { type: "object" } },
    { name: 42, description: "x", input_schema: { type: "object" } },
    { name: "array_schema", description: "x", input_schema: ["not", "an", "object"] },
  ]);
  expect(out).toEqual([
    { name: "page_read", description: "", input_schema: { type: "object", properties: { id: { type: "string" } } } },
    { name: "page_create", description: "Create a page.", input_schema: { type: "object" } },
    { name: "no_schema", description: "No schema.", input_schema: { type: "object" } },
  ]);
  expect(() => normalizeTools([{ name: "twice" }, { name: "twice" }])).toThrow();
});

test("PIN: comparePins reports a changed description, a removed tool and a changed adapter as needs_review", () => {
  const a = tool("tool_a");
  const b = tool("tool_b");
  const c = tool("tool_c");
  const pinned = pinsOf([a, b, c]);

  // Unchanged, plus a newly listed extra tool, which is ignored.
  expect(comparePins(pinned, [c, a, b, tool("tool_new")], "mcp", "mcp")).toEqual({
    changed: [],
    removed: [],
    adapter_changed: false,
    needs_review: false,
  });

  // A changed description.
  expect(comparePins(pinned, [a, { ...b, description: "Now also deletes everything." }, c], "mcp", "mcp")).toEqual({
    changed: ["tool_b"],
    removed: [],
    adapter_changed: false,
    needs_review: true,
  });

  // A changed input schema counts as changed too.
  const cWider = { ...c, input_schema: { type: "object", properties: { extra: { type: "string" } } } };
  expect(comparePins(pinned, [a, b, cWider], "mcp", "mcp").changed).toEqual(["tool_c"]);

  // A removed tool (removed is sorted).
  expect(comparePins(pinned, [b], "mcp", "mcp")).toEqual({
    changed: [],
    removed: ["tool_a", "tool_c"],
    adapter_changed: false,
    needs_review: true,
  });

  // A changed adapter.
  expect(comparePins(pinned, [a, b, c], "composio", "mcp")).toEqual({
    changed: [],
    removed: [],
    adapter_changed: true,
    needs_review: true,
  });
});

test("PIN: recordPins maps a unique violation to PinExistsError and never upserts", async () => {
  const queries: { text: string; values: unknown[] | undefined }[] = [];
  const tx: SqlTx = {
    async query(text: string, values?: unknown[]) {
      queries.push({ text, values });
      if (/^\s*insert/i.test(text)) {
        throw Object.assign(new Error("duplicate key value violates unique constraint"), { code: "23505" });
      }
      return { rows: [], rowCount: 0 };
    },
  };
  const err = await recordPins(tx, "0190a3c4-5b6d-7e8f-9a0b-1c2d3e4f5a6b", [tool("tool_a")]).then(
    () => null,
    (e: unknown) => e,
  );
  expect(err).toBeInstanceOf(PinExistsError);
  expect((err as PinExistsError).code).toBe("pin_exists");
  expect((err as PinExistsError).tool).toBe("tool_a");
  for (const q of queries) expect(q.text.toLowerCase()).not.toContain("on conflict");
});
