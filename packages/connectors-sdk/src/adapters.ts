import { toolName } from "@offload/contracts/src/connections/index.ts";
import type { BrokerPort, ListToolsInput, RawTool } from "./broker-port.ts";
import { isComposioMetaTool } from "./composio.ts";
import type { ConnectionRef, ConnectorAdapter, NormalizedTool } from "./port.ts";

/**
 * Adapters for `mcp`, `composio` and `openapi` (ADR 0010). Tool listing goes through BrokerPort.listTools (the broker
 * holds the token); the adapter only parses and normalises. Tool descriptions are untrusted text and are never logged.
 */

function isPlainObject(v: unknown): v is Record<string, unknown> {
  if (v === null || typeof v !== "object" || Array.isArray(v)) return false;
  const proto = Object.getPrototypeOf(v) as unknown;
  return proto === Object.prototype || proto === null;
}

/**
 * Reduces listed tools to `{ name, description, input_schema }` in input order. Annotations and every other key are
 * dropped; tools with an invalid name or a schema that is not a plain object are dropped; Composio meta tools are
 * dropped. Two tools with the same name throw.
 */
export function normalizeTools(raw: readonly RawTool[]): NormalizedTool[] {
  const out: NormalizedTool[] = [];
  const seen = new Set<string>();
  for (const tool of raw) {
    if (!isPlainObject(tool)) continue;
    const name = tool.name;
    if (typeof name !== "string" || !toolName.safeParse(name).success) continue;
    if (isComposioMetaTool(name)) continue;
    const schema = tool.input_schema !== undefined ? tool.input_schema : tool.inputSchema;
    let input_schema: Record<string, unknown>;
    if (schema === undefined) input_schema = { type: "object" };
    else if (isPlainObject(schema)) input_schema = structuredClone(schema);
    else continue;
    const description = typeof tool.description === "string" ? tool.description : "";
    if (seen.has(name)) throw new Error(`tool ${name} is listed twice`);
    seen.add(name);
    out.push({ name, description, input_schema });
  }
  return out;
}

/** The connector adapter for one kind. For `composio`, `conn.composio` is required and the list is cut to its
 * allowlist. */
export function createAdapter(kind: "mcp" | "composio" | "openapi", broker: BrokerPort): ConnectorAdapter {
  return {
    kind,
    async listTools(conn: ConnectionRef): Promise<NormalizedTool[]> {
      const input: ListToolsInput = { tenant_id: conn.tenant_id, connection_id: conn.connection_id };
      if (kind === "composio") {
        if (!conn.composio) throw new Error("a composio connection needs a Composio session");
        input.composio = conn.composio;
        const allowed = new Set(conn.composio.tools);
        return normalizeTools(await broker.listTools(input)).filter((t) => allowed.has(t.name));
      }
      return normalizeTools(await broker.listTools(input));
    },
  };
}
