import type { Adapter } from "@offload/contracts/src/connections/index.ts";
import type { BrokerPort, ComposioSession } from "./broker-port.ts";

/**
 * The connector port (ADR 0010, ARCHITECTURE section 10). Tool listing for `mcp`, `composio` and `openapi` goes
 * through BrokerPort.listTools (the broker holds the token); the adapter parses and normalises what it lists.
 * `browser` arrives in M6.
 */

/** A listed tool reduced to the three fields the pin hash covers. Annotations are dropped. */
export interface NormalizedTool {
  name: string;
  description: string;
  input_schema: Record<string, unknown>;
}

/** What an adapter needs to know about a connection. Ids only, no secret. */
export interface ConnectionRef {
  tenant_id: string;
  connection_id: string;
  adapter: Adapter;
  provider: string;
  /** Required when adapter is `composio`. */
  composio?: ComposioSession;
}

export interface ConnectorAdapter {
  readonly kind: Adapter;
  listTools(conn: ConnectionRef): Promise<NormalizedTool[]>;
}

/** Signature of the factory implemented in adapters.ts. */
export type CreateAdapter = (kind: "mcp" | "composio" | "openapi", broker: BrokerPort) => ConnectorAdapter;
