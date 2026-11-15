import { createHash, timingSafeEqual } from "node:crypto";
import { chmodSync, existsSync, lstatSync, unlinkSync } from "node:fs";
import type { Pool } from "pg";
import type { ZodType } from "zod";
import { jcs, sha256Hex } from "@offload/contracts";
import {
  ApiKeyRequestSchema, BROKER_ERROR_STATUS, CallRequestSchema, OAuthBeginRequestSchema, OAuthFinishRequestSchema, ShredRequestSchema,
  ToolsListRequestSchema, type ApprovalVerifier, type BrokerErrorCode, type CallRequest, type KeyProvider, type RunScopeSource,
} from "@offload/contracts/src/broker/index.ts";
import { appendAudit, withTenant } from "@offload/db";
import { BrokerError } from "./errors.ts";
import { checkHost, DEFAULT_COMPOSIO_HOSTS, type ComposioConfig, type ProviderConfig, type ProviderTable } from "./egress/hosts.ts";
import { send } from "./egress/http.ts";
import type { Logger } from "./log.ts";
import { createOAuth } from "./oauth.ts";
import { createRefresher, type RefreshResult } from "./refresh.ts";
import { BROKER_PRINCIPAL, brokerCtx, Vault, type VaultSecret } from "./vault/vault.ts";

/**
 * The credential broker (ADR 0034): the one process with decrypt rights. JSON over HTTP on a Unix socket, every request
 * carries the service token. Reads are checked against the run's declared read set (or a fixture capture scope) and
 * commits against the approved item hash before any credential is decrypted; the credential is added only to the
 * outbound request and never leaves in a response.
 */

export interface BrokerDeps {
  pool: Pool;
  keys: KeyProvider;
  clock: { now(): Date };
  scope: RunScopeSource;
  approvals: ApprovalVerifier;
  providers: ProviderTable;
  serviceToken: string;
  logger: Logger;
  /** Composio adapter: the API key lives in the broker's config, not in the vault. */
  composio: ComposioConfig | null;
  /** How long a refresh caller waits for another caller's lease, in ms (default 5000). */
  leaseWaitMs?: number;
}

export interface Broker {
  vault: Vault;
  refresh(tenantId: string, connectionId: string, opts?: { staleBefore?: Date }): Promise<RefreshResult>;
  handle(req: Request): Promise<Response>;
  listen(socketPath: string): Promise<{ stop(): Promise<void> }>;
}

interface ConnectionRow {
  adapter: string;
  provider: string;
  member_id: string | null;
  state: "active" | "needs_reauth" | "revoked";
}

/** Headers a caller can never set: the broker owns authentication and framing. */
const DROPPED_HEADERS = new Set([
  "authorization", "proxy-authorization", "cookie", "x-api-key", "api-key", "x-auth-token", "host", "content-length", "connection",
  "transfer-encoding", "upgrade", "te", "keep-alive", "x-forwarded-for", "x-forwarded-host",
]);

const TOKEN_SKEW_MS = 60_000;
const CAPABILITY_RE = /^[A-Za-z0-9_.:-]{1,128}$/;

export function createBroker(deps: BrokerDeps): Broker {
  const { pool, clock, logger } = deps;
  const vault = new Vault({ pool, keys: deps.keys, clock, logger });
  const expectedToken = createHash("sha256").update(deps.serviceToken).digest();

  async function loadConnection(tenantId: string, connectionId: string): Promise<ConnectionRow> {
    const row = await withTenant(pool, brokerCtx(tenantId), async (tx) =>
      (await tx.query<ConnectionRow>("select adapter, provider, member_id, state from connections where tenant_id = $1 and id = $2", [tenantId, connectionId])).rows[0],
    );
    if (!row) throw new BrokerError("not_found", "connection not found");
    return row;
  }

  const refresh = createRefresher({
    pool, vault, clock, logger, leaseWaitMs: deps.leaseWaitMs ?? 5000,
    async oauthFor(tenantId, connectionId) {
      const c = await loadConnection(tenantId, connectionId);
      return deps.providers[c.provider]?.oauth ?? null;
    },
  });
  const oauth = createOAuth({ pool, vault, providers: deps.providers, clock, logger });

  /** Audits a refusal (ids and hashes only) and throws it. */
  async function refuse(tenantId: string, connectionId: string, code: BrokerErrorCode, message: string, extra: Record<string, string> = {}): Promise<never> {
    try {
      await withTenant(pool, brokerCtx(tenantId), (tx) =>
        appendAudit(tx, {
          principalId: BROKER_PRINCIPAL, action: "broker.refused", subjectType: "connection", subjectId: connectionId,
          details: { code, connection_id: connectionId, ...extra },
        }),
      );
    } catch {
      logger.error("broker.refused_audit_failed", { tenant_id: tenantId, connection_id: connectionId });
    }
    logger.warn("broker.refused", { code, tenant_id: tenantId, connection_id: connectionId });
    throw new BrokerError(code, message);
  }

  function providerFor(conn: ConnectionRow): { hosts: readonly string[]; allowHttp: boolean | undefined; cfg: ProviderConfig | null } {
    if (conn.adapter === "composio") {
      const hosts = deps.composio?.hosts ?? DEFAULT_COMPOSIO_HOSTS;
      return { hosts, allowHttp: deps.composio?.allowHttp, cfg: null };
    }
    const cfg = deps.providers[conn.provider];
    return { hosts: cfg?.hosts ?? [], allowHttp: cfg?.allowHttp, cfg: cfg ?? null };
  }

  /** The secret to present for this connection: its access token or api key, refreshed first when it is about to expire. */
  async function usableSecret(tenantId: string, connectionId: string): Promise<VaultSecret> {
    let row = await vault.readRow(tenantId, connectionId);
    if (!row) throw new BrokerError("not_found", "no credential for this connection");
    if (row.refresh_state === "failed" || row.refresh_state === "revoked") throw new BrokerError("state_conflict", "the credential needs re-authorization");
    const stale = new Date(clock.now().getTime() + TOKEN_SKEW_MS);
    if (row.expires_at !== null && row.expires_at.getTime() <= stale.getTime()) {
      await refresh(tenantId, connectionId, { staleBefore: stale });
      row = await vault.readRow(tenantId, connectionId);
      if (!row) throw new BrokerError("not_found", "no credential for this connection");
    }
    return vault.openRow(tenantId, connectionId, row);
  }

  function authHeader(cfg: ProviderConfig | null, secret: VaultSecret): [string, string] {
    const token = secret.kind === "oauth" ? secret.access_token : secret.api_key;
    const a = cfg?.auth ?? { header: "authorization", scheme: "bearer" as const };
    return [a.header.toLowerCase(), a.scheme === "bearer" ? `Bearer ${token}` : token];
  }

  function redact(text: string, secrets: string[]): string {
    let out = text;
    for (const s of secrets) {
      if (s.length < 4) continue;
      for (const v of new Set([s, encodeURIComponent(s), Buffer.from(s).toString("base64")])) out = out.split(v).join("[redacted]");
    }
    return out;
  }

  function cleanHeaders(headers: Record<string, string>): Record<string, string> {
    const out: Record<string, string> = {};
    for (const [k, v] of Object.entries(headers)) {
      const key = k.toLowerCase();
      if (!DROPPED_HEADERS.has(key) && /^[a-z0-9-]{1,64}$/.test(key)) out[key] = v;
    }
    return out;
  }

  async function handleCall(req: CallRequest) {
    const t = req.tenant_id;
    const conn = await loadConnection(t, req.connection_id);
    const capability = CAPABILITY_RE.test(req.capability) ? req.capability : sha256Hex(req.capability);
    if (conn.state !== "active") throw new BrokerError("state_conflict", `the connection is ${conn.state}`);

    if (req.kind === "commit") {
      if (req.gate_mode === "read") return refuse(t, req.connection_id, "gate_read_only", "gate mode read refuses commit capabilities", { capability });
      let itemHash: string;
      try {
        itemHash = sha256Hex(jcs(req.arguments));
      } catch {
        throw new BrokerError("invalid_request", "arguments are not canonical JSON");
      }
      if (!req.approval_id) return refuse(t, req.connection_id, "forbidden", "a commit needs an approval", { capability, item_hash: itemHash });
      const verdict = await deps.approvals.check(t, req.approval_id, itemHash);
      if (verdict !== "ok") {
        return refuse(t, req.connection_id, verdict, "the approval does not cover this item", { capability, item_hash: itemHash, approval_id: req.approval_id });
      }
    } else {
      const declared =
        req.gate_mode === "read" && req.fixture_set_id !== undefined
          ? await deps.scope.fixtureScope(t, req.fixture_set_id)
          : req.run_id !== undefined
            ? await deps.scope.readSet(t, req.run_id)
            : null;
      if (!declared || !declared.includes(req.capability)) {
        return refuse(t, req.connection_id, "read_not_declared", "the capability is not in the declared read set", { capability });
      }
    }

    const { hosts, allowHttp, cfg } = providerFor(conn);
    let url: URL;
    try {
      url = checkHost(req.request.url, hosts, allowHttp);
    } catch (e) {
      if (e instanceof BrokerError && e.code === "host_not_allowed") return refuse(t, req.connection_id, "host_not_allowed", e.message, { capability });
      throw e;
    }

    // Everything above ran before any decrypt. From here the credential is used.
    const headers = cleanHeaders(req.request.headers);
    let body = req.request.body ?? null;
    const secrets: string[] = [];
    if (conn.adapter === "composio") {
      if (!deps.composio) throw new BrokerError("server_error", "composio is not configured");
      headers["x-api-key"] = deps.composio.apiKey;
      secrets.push(deps.composio.apiKey);
      // The member uuid is the Composio user_id and the caller cannot choose it: overwrite, never default.
      if (!conn.member_id) {
        return refuse(t, req.connection_id, "invalid_request", "the connection has no member to act as", { capability });
      }
      if (body !== null) {
        try {
          const parsed: unknown = JSON.parse(body);
          if (parsed !== null && typeof parsed === "object" && !Array.isArray(parsed)) {
            (parsed as Record<string, unknown>)["user_id"] = conn.member_id;
            body = JSON.stringify(parsed);
          }
        } catch {
          /* not JSON: the query string carries it */
        }
      }
      // Always pin the query string too (set replaces every caller-supplied user_id).
      url.searchParams.set("user_id", conn.member_id);
    } else {
      const secret = await usableSecret(t, req.connection_id);
      const [name, value] = authHeader(cfg, secret);
      headers[name] = value;
      secrets.push(secret.kind === "oauth" ? secret.access_token : secret.api_key);
    }

    const res = await send({ method: req.request.method, url: url.toString(), headers, body });
    logger.info("broker.call", { tenant_id: t, connection_id: req.connection_id, capability, kind: req.kind, status: res.status });
    return {
      status: res.status,
      headers: res.contentType ? { "content-type": redact(res.contentType, secrets) } : {},
      body: redact(res.body, secrets),
    };
  }

  async function handleToolsList(tenantId: string, connectionId: string) {
    const conn = await loadConnection(tenantId, connectionId);
    if (conn.state !== "active") throw new BrokerError("state_conflict", `the connection is ${conn.state}`);
    const { hosts, allowHttp, cfg } = providerFor(conn);
    const headers: Record<string, string> = { accept: "application/json" };
    let method = "GET";
    let body: string | null = null;
    let target: string;
    const secrets: string[] = [];
    if (conn.adapter === "composio") {
      if (!deps.composio) throw new BrokerError("server_error", "composio is not configured");
      const host = deps.composio.hosts[0] ?? DEFAULT_COMPOSIO_HOSTS[0];
      target = `${deps.composio.allowHttp ? "http" : "https"}://${host}/api/v3/tools?toolkit_slug=${encodeURIComponent(conn.provider)}&limit=1000`;
      headers["x-api-key"] = deps.composio.apiKey;
      secrets.push(deps.composio.apiKey);
    } else {
      const mcp = cfg?.mcpToolsUrl;
      const url = mcp ?? cfg?.toolsUrl;
      if (!url) throw new BrokerError("invalid_request", "this provider does not list tools");
      target = url;
      if (mcp) {
        method = "POST";
        headers["content-type"] = "application/json";
        body = JSON.stringify({ jsonrpc: "2.0", id: 1, method: "tools/list" });
      }
    }
    const u = checkHost(target, hosts, allowHttp);
    if (conn.adapter !== "composio") {
      const secret = await usableSecret(tenantId, connectionId);
      const [name, value] = authHeader(cfg, secret);
      headers[name] = value;
      secrets.push(secret.kind === "oauth" ? secret.access_token : secret.api_key);
    }
    const res = await send({ method, url: u.toString(), headers, body });
    if (res.status < 200 || res.status >= 300) throw new BrokerError("upstream_unreachable", `the provider answered ${res.status} to the tool list`);
    let parsed: unknown;
    try {
      parsed = JSON.parse(redact(res.body, secrets));
    } catch {
      throw new BrokerError("upstream_unreachable", "the provider's tool list is not JSON");
    }
    const obj = (parsed ?? {}) as Record<string, unknown>;
    const result = (obj["result"] ?? {}) as Record<string, unknown>;
    const list = Array.isArray(parsed) ? parsed : (result["tools"] ?? obj["tools"] ?? obj["items"]);
    if (!Array.isArray(list)) throw new BrokerError("upstream_unreachable", "the provider's tool list has an unknown shape");
    return { tools: list.filter((t): t is Record<string, unknown> => t !== null && typeof t === "object" && !Array.isArray(t)) };
  }

  async function putApiKey(tenantId: string, connectionId: string, apiKey: string) {
    const conn = await loadConnection(tenantId, connectionId);
    if (conn.state === "revoked") throw new BrokerError("state_conflict", "the connection is revoked");
    await vault.put(tenantId, connectionId, { kind: "api_key", api_key: apiKey }, { scopes: [], expiresAt: null });
    await withTenant(pool, brokerCtx(tenantId), (tx) => tx.query("update connections set state = 'active' where tenant_id = $1 and id = $2", [tenantId, connectionId]));
    return { account_label: `${conn.provider} key ending ${apiKey.slice(-4)}`.slice(0, 256), account_hash: sha256Hex(sha256Hex(apiKey)) };
  }

  async function shred(tenantId: string, connectionId: string): Promise<void> {
    await vault.shred(tenantId, connectionId);
    await withTenant(pool, brokerCtx(tenantId), (tx) =>
      tx.query("update connections set state = 'revoked' where tenant_id = $1 and id = $2 and state <> 'revoked'", [tenantId, connectionId]),
    );
  }

  function authorized(req: Request): boolean {
    const h = req.headers.get("authorization") ?? "";
    const m = /^Bearer (.+)$/.exec(h);
    if (!m) return false;
    return timingSafeEqual(createHash("sha256").update(m[1]!).digest(), expectedToken);
  }

  function errorResponse(code: BrokerErrorCode, message: string): Response {
    return Response.json({ error: { code, message } }, { status: BROKER_ERROR_STATUS[code] });
  }

  async function parse<T>(req: Request, schema: ZodType<T>): Promise<T> {
    let raw: unknown;
    try {
      raw = await req.json();
    } catch {
      throw new BrokerError("invalid_request", "body is not JSON");
    }
    const r = schema.safeParse(raw);
    if (!r.success) throw new BrokerError("invalid_request", `invalid request body: ${r.error.issues.map((i) => i.path.join(".") || "(root)").slice(0, 5).join(", ")}`);
    return r.data;
  }

  async function route(req: Request, path: string): Promise<Response> {
    switch (path) {
      case "/oauth/begin":
        return Response.json(await oauth.begin(await parse(req, OAuthBeginRequestSchema)));
      case "/oauth/finish":
        return Response.json(await oauth.finish(await parse(req, OAuthFinishRequestSchema)));
      case "/credentials/api-key": {
        const b = await parse(req, ApiKeyRequestSchema);
        return Response.json(await putApiKey(b.tenant_id, b.connection_id, b.api_key));
      }
      case "/credentials/shred": {
        const b = await parse(req, ShredRequestSchema);
        await shred(b.tenant_id, b.connection_id);
        return new Response(null, { status: 204 });
      }
      case "/tools/list": {
        const b = await parse(req, ToolsListRequestSchema);
        return Response.json(await handleToolsList(b.tenant_id, b.connection_id));
      }
      case "/call":
        return Response.json(await handleCall(await parse(req, CallRequestSchema)));
      default:
        throw new BrokerError("not_found", "unknown route");
    }
  }

  async function handle(req: Request): Promise<Response> {
    // Authentication first: nothing is parsed or looked up for a caller without the service token.
    if (!authorized(req)) return errorResponse("unauthenticated", "missing or wrong service token");
    const path = new URL(req.url).pathname;
    try {
      if (req.method !== "POST") throw new BrokerError("not_found", "unknown route");
      return await route(req, path);
    } catch (e) {
      if (e instanceof BrokerError) return errorResponse(e.code, e.message);
      // Error text can hold row values: log the error class and the Postgres SQLSTATE only.
      const pg = (e as { code?: unknown }).code;
      logger.error("broker.internal_error", { route: path, error: e instanceof Error ? e.name : "unknown", sqlstate: typeof pg === "string" && /^[0-9A-Z]{5}$/.test(pg) ? pg : null });
      return errorResponse("server_error", "internal error");
    }
  }

  async function listen(socketPath: string) {
    if (existsSync(socketPath)) {
      if (!lstatSync(socketPath).isSocket()) throw new Error("broker socket path exists and is not a socket");
      unlinkSync(socketPath); // stale socket of a previous run
    }
    const oldUmask = process.umask(0o177);
    let server: ReturnType<typeof Bun.serve>;
    try {
      server = Bun.serve({ unix: socketPath, maxRequestBodySize: 16_000_000, fetch: (req) => handle(req) });
    } finally {
      process.umask(oldUmask);
    }
    chmodSync(socketPath, 0o600);
    return {
      stop: async () => {
        await server.stop(true);
        if (existsSync(socketPath)) unlinkSync(socketPath);
      },
    };
  }

  return { vault, refresh, handle, listen };
}
