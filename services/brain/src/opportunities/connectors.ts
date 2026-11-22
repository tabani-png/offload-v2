// Connector resolution for proposed fixes (ADR 0033, ADR 0010): MCP, then Composio, then a direct API, then the browser.
import type { Adapter, ConnectorChoice, System, TenantCatalog } from "./types.ts";

export const ADAPTER_ORDER: readonly Adapter[] = ["mcp", "composio", "openapi", "browser"];

export interface CatalogApp {
  provider: string;
  label: string;
  hosts: readonly string[];
  apps: readonly string[];
  methods: readonly Adapter[];
}

export const LAUNCH_CATALOG: readonly CatalogApp[] = [];

export function resolveConnector(_system: System, _catalog?: TenantCatalog): ConnectorChoice {
  throw new Error("not implemented");
}
