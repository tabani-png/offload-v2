import type { Adapter, ToolPin } from "@offload/contracts/src/connections/index.ts";
import { jcs, sha256Hex } from "@offload/contracts";
import { isComposioMetaTool } from "./composio.ts";
import type { NormalizedTool } from "./port.ts";

/**
 * Connection pins (ADR 0033): the hash of each tool's name, description and input schema, stored at connect and
 * compared before a run. Annotations (`readOnlyHint` and the rest) are never hashed and never used for decisions.
 */

/** Structurally what @offload/db's `Tx` is; this package does not import @offload/db. */
export interface SqlTx {
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  query(text: string, values?: unknown[]): Promise<{ rows: any[]; rowCount: number | null }>;
}

/** A Composio meta tool can never be pinned. */
export class PinRefusedError extends Error {
  readonly code = "pin_refused";
  constructor(readonly tool: string) {
    super(`tool ${tool} is a Composio meta tool and cannot be pinned`);
    this.name = "PinRefusedError";
  }
}

/** The tool name already has a pin; pins change only through repair or re-approval. */
export class PinExistsError extends Error {
  readonly code = "pin_exists";
  constructor(readonly tool: string) {
    super(`tool ${tool} is already pinned for this connection`);
    this.name = "PinExistsError";
  }
}

/** sha256 hex of the JCS of `{ name, description, input_schema }`. Every other key of `tool` is ignored. */
export function toolPinHash(tool: NormalizedTool): string {
  return sha256Hex(jcs({ name: tool.name, description: tool.description, input_schema: tool.input_schema }));
}

function isUniqueViolation(err: unknown): boolean {
  return err !== null && typeof err === "object" && (err as { code?: unknown }).code === "23505";
}

/**
 * Writes `connection_tool_pins` inside the caller's withTenant transaction. Refuses meta tools before writing anything.
 * Never overwrites: an existing pin for a tool name throws PinExistsError (even with an identical hash).
 * Returns the pins sorted by name.
 */
export async function recordPins(tx: SqlTx, connectionId: string, tools: readonly NormalizedTool[]): Promise<ToolPin[]> {
  for (const t of tools) if (isComposioMetaTool(t.name)) throw new PinRefusedError(t.name);
  const names = new Set<string>();
  for (const t of tools) {
    if (names.has(t.name)) throw new PinExistsError(t.name);
    names.add(t.name);
  }
  if (tools.length === 0) return [];

  const pins = tools
    .map((t) => ({ name: t.name, pin_hash: toolPinHash(t) }))
    .sort((a, b) => (a.name < b.name ? -1 : a.name > b.name ? 1 : 0));

  const existing = await tx.query(
    "select tool_name from connection_tool_pins where connection_id = $1 and tool_name = any($2::text[]) order by tool_name",
    [connectionId, pins.map((p) => p.name)],
  );
  const first = existing.rows[0] as { tool_name?: unknown } | undefined;
  if (first) throw new PinExistsError(String(first.tool_name));

  for (const pin of pins) {
    try {
      await tx.query(
        `insert into connection_tool_pins (tenant_id, connection_id, tool_name, pin_hash)
         values (nullif(current_setting('app.tenant_id', true), '')::uuid, $1, $2, $3)`,
        [connectionId, pin.name, pin.pin_hash],
      );
    } catch (err) {
      if (isUniqueViolation(err)) throw new PinExistsError(pin.name);
      throw err;
    }
  }
  return pins;
}

export interface PinComparison {
  /** Pinned tools still listed but with a different hash. */
  changed: string[];
  /** Pinned tools no longer listed. */
  removed: string[];
  adapter_changed: boolean;
  needs_review: boolean;
}

/** Pure. Newly listed tools are ignored. The runtime (m2-10) calls this before each run. */
export function comparePins(
  pinned: readonly ToolPin[],
  listed: readonly NormalizedTool[],
  pinnedAdapter: Adapter,
  currentAdapter: Adapter,
): PinComparison {
  const current = new Map(listed.map((t) => [t.name, toolPinHash(t)]));
  const changed: string[] = [];
  const removed: string[] = [];
  for (const pin of pinned) {
    const hash = current.get(pin.name);
    if (hash === undefined) removed.push(pin.name);
    else if (hash !== pin.pin_hash) changed.push(pin.name);
  }
  changed.sort();
  removed.sort();
  const adapter_changed = pinnedAdapter !== currentAdapter;
  return {
    changed,
    removed,
    adapter_changed,
    needs_review: changed.length > 0 || removed.length > 0 || adapter_changed,
  };
}
