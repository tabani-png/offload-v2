/**
 * BrokerPort: the only way the connections code reaches a secret (ADR 0034, slice m2-03). The broker holds OAuth
 * client secrets, tokens, API keys and the Composio API key; PKCE, `state` and the code exchange happen inside it.
 * m2-02 defines the port; the real broker client is wired in m2-04. A fake lives in packages/testkit/src/connectors.
 *
 * Every method is network I/O: callers must never call it inside withTenant or withTransaction (ADR 0013).
 */

/** A Composio session: opaque member uuid as `user_id` (never an email), one toolkit, an explicit tool allowlist. */
export interface ComposioSession {
  user_id: string;
  toolkit: string;
  tools: string[];
}

/** A tool exactly as a connector listed it (untrusted: its description is never logged). */
export interface RawTool {
  name?: unknown;
  description?: unknown;
  /** MCP spells it `inputSchema`; Composio and OpenAPI listings are normalised by the broker to either spelling. */
  input_schema?: unknown;
  inputSchema?: unknown;
  annotations?: unknown;
  [key: string]: unknown;
}

export interface OAuthBeginInput {
  tenant_id: string;
  connection_id: string;
  provider: string;
  scopes: string[];
  redirect_uri: string;
  /** Present for adapter `composio` only. */
  composio?: ComposioSession;
}

export interface OAuthFinishInput {
  tenant_id: string;
  state: string;
  code: string;
}

export interface OAuthFinishResult {
  connection_id: string;
  account_label: string;
  /** sha256 hex of the provider account id. */
  account_hash: string;
  scopes: string[];
}

export interface PutApiKeyInput {
  tenant_id: string;
  connection_id: string;
  /** The raw key: travels to the broker only. */
  api_key: string;
}

export interface ListToolsInput {
  tenant_id: string;
  connection_id: string;
  /** Present for adapter `composio` only. */
  composio?: ComposioSession;
}

export interface BrokerPort {
  oauthBegin(input: OAuthBeginInput): Promise<{ authorize_url: string }>;
  oauthFinish(input: OAuthFinishInput): Promise<OAuthFinishResult>;
  putApiKey(input: PutApiKeyInput): Promise<{ account_label: string; account_hash: string }>;
  listTools(input: ListToolsInput): Promise<RawTool[]>;
  /** Crypto-shreds the connection's credential. Idempotent. */
  shred(input: { tenant_id: string; connection_id: string }): Promise<void>;
}
