import { z } from "zod";
import { hex64, rfc3339, uuid } from "../primitives.ts";

/**
 * Connections, the launch catalog, capabilities and tool pins (ADR 0033, ADR 0010, docs/API.md "Connections").
 * m2-02-connections-catalog. Not re-exported from the package barrel: import by subpath
 * (`@offload/contracts/src/connections/index.ts`).
 *
 * Secrets never appear in a response shape: `Connection` has no `external_ref`, no `account_hash`, no token field.
 * `ConnectionCreate.api_key` is write-only (passed straight to the broker).
 */

export const ADAPTERS = ["mcp", "composio", "openapi", "browser"] as const;
export const AdapterSchema = z.enum(ADAPTERS);
export type Adapter = z.infer<typeof AdapterSchema>;

export const CATALOG_METHODS = ["google_internal", "composio", "mcp", "openapi"] as const;
export const CatalogMethodSchema = z.enum(CATALOG_METHODS);
export type CatalogMethod = z.infer<typeof CatalogMethodSchema>;

export const CONNECTION_STATES = ["active", "needs_reauth", "revoked"] as const;
export const ConnectionStateSchema = z.enum(CONNECTION_STATES);
export type ConnectionState = z.infer<typeof ConnectionStateSchema>;

/** Step classes a capability can have (`transform` and `model` steps have no connector capability). */
export const CAPABILITY_STEP_CLASSES = ["read", "draft", "commit"] as const;
export const CapabilityStepClassSchema = z.enum(CAPABILITY_STEP_CLASSES);
export type CapabilityStepClass = z.infer<typeof CapabilityStepClassSchema>;

/** Stable provider slug, for example `gmail`, `google_sheets`, `stripe`. */
export const providerSlug = z.string().regex(/^[a-z][a-z0-9_]{0,63}$/);
/** Capability name from the fixed vocabulary, for example `mail.send`, `sheet.append`. */
export const capabilityName = z.string().regex(/^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)+$/).max(64);
/** A tool name as a connector lists it (MCP tool names, Composio tool slugs, OpenAPI operation ids). */
export const toolName = z.string().regex(/^[A-Za-z0-9_.:-]{1,128}$/);

/** One app of the launch catalog. `app` is the display name, `provider` the stable slug used everywhere else. */
export const CatalogEntrySchema = z.strictObject({
  app: z.string().min(1).max(64),
  provider: providerSlug,
  method: CatalogMethodSchema,
  adapter: AdapterSchema,
  scopes: z.array(z.string().min(1).max(256)).max(64),
  capabilities: z.array(capabilityName).max(64),
  /** When spike S5 confirmed this entry on the owner's accounts; null = unverified, not offered. */
  s5_verified_at: rfc3339.nullable(),
});
export type CatalogEntry = z.infer<typeof CatalogEntrySchema>;

export const ConnectionSchema = z.strictObject({
  connection_id: uuid,
  workspace_id: uuid,
  /** null = a workspace connection; else the member whose personal connection this is. */
  member_id: uuid.nullable(),
  adapter: AdapterSchema,
  provider: providerSlug,
  /** Shown on the deploy card; null until the connection is first activated. */
  account_label: z.string().max(256).nullable(),
  capabilities: z.array(capabilityName),
  state: ConnectionStateSchema,
  created_at: rfc3339,
});
export type Connection = z.infer<typeof ConnectionSchema>;

export const ConnectionCreateSchema = z.strictObject({
  adapter: AdapterSchema,
  provider: providerSlug,
  workspace_id: uuid,
  personal: z.boolean(),
  /** Write-only. Only for catalog method `openapi` (a Stripe restricted key); handed to the broker, never stored,
   * logged or echoed by the API. */
  api_key: z.string().min(1).max(512).optional(),
});
export type ConnectionCreate = z.infer<typeof ConnectionCreateSchema>;

export const ConnectionCreatedSchema = z.strictObject({
  connection_id: uuid,
  authorize_url: z.url().max(4096).optional(),
});
export type ConnectionCreated = z.infer<typeof ConnectionCreatedSchema>;

export const ToolPinSchema = z.strictObject({ name: toolName, pin_hash: hex64 });
export type ToolPin = z.infer<typeof ToolPinSchema>;

export const ToolPinListSchema = z.strictObject({ tools: z.array(ToolPinSchema) });
export type ToolPinList = z.infer<typeof ToolPinListSchema>;

/** A JSON Schema (2020-12) object describing a capability's arguments. */
export const ArgumentSchemaSchema = z.record(z.string(), z.unknown());

export const CapabilitySchema = z.strictObject({
  name: capabilityName,
  step_class: CapabilityStepClassSchema,
  argument_schema: ArgumentSchemaSchema,
  /** Required for `commit` capabilities: the only argument names a commit may carry. */
  commit_arguments_allowlist: z.array(z.string().min(1).max(64)).min(1).optional(),
});
export type Capability = z.infer<typeof CapabilitySchema>;
