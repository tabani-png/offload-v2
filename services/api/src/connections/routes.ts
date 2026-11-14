import type { Context, Hono } from "hono";
import type { Pool } from "pg";
import { jcs, sha256Hex } from "@offload/contracts";
import {
  CapabilitySchema, CatalogEntrySchema, ConnectionCreateSchema, ConnectionCreatedSchema, ConnectionSchema, ToolPinListSchema,
  type Adapter, type CatalogEntry, type Connection, type ConnectionCreated,
} from "@offload/contracts/src/connections/index.ts";
import {
  CAPABILITIES, availableEntries, composioSession, createAdapter, findEntry, launchCatalog, recordPins,
  type BrokerPort, type ComposioSession,
} from "@offload/connectors-sdk";
import { appendAudit, uuidv7, withTenant, type TenantContext, type Tx } from "@offload/db";
import type { Clock } from "../clock.ts";
import { ApiError, invalidRequest } from "../http.ts";

/**
 * Connections, the launch catalog and capabilities (m2-02, docs/API.md "Connections"). Every secret stays in the
 * broker: this code reaches it only through BrokerPort, and every broker call runs between short withTenant
 * transactions, never inside one (ADR 0013). A Stripe api_key is handed to the broker and is never stored, logged,
 * audited, hashed into a row or echoed. Responses are built field by field and parsed with the contract schemas, so
 * `external_ref` and `account_hash` never leave the database.
 */

export type ConnectionsRole = "owner" | "admin" | "member" | "auditor";

export interface ConnectionsPrincipal {
  tenantId: string;
  memberId: string;
  tenantRole: ConnectionsRole;
  via: "session" | "member_token";
}

export interface ConnectionsDeps {
  /** Pool connected as offload_app. */
  pool: Pool;
  /** Absent: POST /v1/connections, the callback and DELETE answer 404 not_found. */
  broker?: BrokerPort | undefined;
  /** Session cookie (CSRF on mutations) or member token. */
  authenticate(c: Context): Promise<ConnectionsPrincipal>;
  clock: Clock;
  /** No trailing slash. */
  publicBaseUrl: string;
  /** Default: the shipped launch catalog. */
  catalog?: CatalogEntry[] | undefined;
  /** JSON-only body reader with the size limit. */
  jsonBody(c: Context): Promise<unknown>;
}

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const STATE_RE = /^[\x21-\x7e]{1,512}$/;
const ULID_RE = /^[0-7][0-9A-HJKMNP-TV-Z]{25}$/;
const MAX_LABEL = 256;

const notFound = (what = "no such connection") => new ApiError(404, "not_found", what);
const noBroker = () => new ApiError(404, "not_found", "connections are not configured");

interface ConnectionRow {
  id: string;
  workspace_id: string;
  member_id: string | null;
  adapter: Adapter;
  provider: string;
  account_label: string | null;
  capabilities: string[];
  state: "active" | "needs_reauth" | "revoked";
  created_at: Date;
}

const COLUMNS = "id, workspace_id, member_id, adapter, provider, account_label, capabilities, state, created_at";

/** The wire shape, built explicitly (no external_ref, no account_hash) and checked against the contract. */
function toConnection(r: ConnectionRow): Connection {
  return ConnectionSchema.parse({
    connection_id: r.id,
    workspace_id: r.workspace_id,
    member_id: r.member_id,
    adapter: r.adapter,
    provider: r.provider,
    account_label: r.account_label,
    capabilities: [...r.capabilities],
    state: r.state,
    created_at: r.created_at.toISOString(),
  });
}

export function mountConnections(app: Hono, deps: ConnectionsDeps): void {
  const pool = deps.pool;
  const base = deps.publicBaseUrl.replace(/\/+$/, "");
  const catalog = (deps.catalog ?? launchCatalog()).map((e) => CatalogEntrySchema.parse(e));
  const capabilities = CAPABILITIES.map((c) => CapabilitySchema.parse(c));

  const ctxOf = (p: ConnectionsPrincipal): TenantContext => ({ tenantId: p.tenantId, principalId: p.memberId, memberId: p.memberId, tenantRole: p.tenantRole });
  const seesAll = (p: ConnectionsPrincipal) => p.tenantRole === "owner" || p.tenantRole === "admin";

  /** A connection the caller may see: workspace connections, the caller's own, and every one for owner and admin. */
  async function visible(tx: Tx, p: ConnectionsPrincipal, id: string, lock = false): Promise<ConnectionRow | undefined> {
    const r = await tx.query<ConnectionRow>(
      `select ${COLUMNS} from connections where id = $1 and (member_id is null or member_id = $2 or $3::boolean)${lock ? " for update" : ""}`,
      [id, p.memberId, seesAll(p)],
    );
    return r.rows[0];
  }

  function composioFor(entry: CatalogEntry | undefined, memberId: string): ComposioSession | undefined {
    if (!entry || entry.method !== "composio") return undefined;
    return composioSession(entry, memberId);
  }

  /** Lists the tools through the adapter (outside any transaction), then records the pins and audits them. */
  async function pinTools(broker: BrokerPort, p: ConnectionsPrincipal, conn: ConnectionRow, composio: ComposioSession | undefined): Promise<void> {
    if (conn.adapter === "browser") return;
    const adapter = createAdapter(conn.adapter, broker);
    const tools = await adapter.listTools({
      tenant_id: p.tenantId, connection_id: conn.id, adapter: conn.adapter, provider: conn.provider, ...(composio ? { composio } : {}),
    });
    await withTenant(pool, ctxOf(p), async (tx) => {
      const pins = await recordPins(tx, conn.id, tools);
      await appendAudit(tx, {
        principalId: p.memberId, action: "connection.pins_recorded", subjectType: "connection", subjectId: conn.id,
        details: { count: pins.length, pins_hash: sha256Hex(jcs(pins)) },
      });
    });
  }

  // ---- catalog and capabilities --------------------------------------------------------------------------------

  app.get("/v1/catalog", async (c) => {
    await deps.authenticate(c);
    return c.json(catalog);
  });

  app.get("/v1/capabilities", async (c) => {
    await deps.authenticate(c);
    return c.json(capabilities);
  });

  // ---- connections ---------------------------------------------------------------------------------------------

  app.get("/v1/connections", async (c) => {
    const p = await deps.authenticate(c);
    const rows = await withTenant(pool, ctxOf(p), async (tx) =>
      (await tx.query<ConnectionRow>(
        `select ${COLUMNS} from connections where member_id is null or member_id = $1 or $2::boolean order by created_at, id`,
        [p.memberId, seesAll(p)],
      )).rows);
    c.header("cache-control", "no-store");
    return c.json(rows.map(toConnection));
  });

  app.post("/v1/connections", async (c) => {
    const broker = deps.broker;
    if (!broker) throw noBroker();
    const p = await deps.authenticate(c);
    const parsed = ConnectionCreateSchema.safeParse(await deps.jsonBody(c));
    if (!parsed.success) throw invalidRequest("body does not match ConnectionCreate");
    const body = parsed.data;
    const entry = findEntry(catalog, body.provider);
    if (!entry || !availableEntries(catalog).some((e) => e.provider === entry.provider)) throw invalidRequest("this app is not available");
    if (entry.adapter !== body.adapter) throw invalidRequest("adapter does not match the catalog entry");
    if (entry.method === "openapi" && body.api_key === undefined) throw invalidRequest("api_key is required for this app");
    if (entry.method !== "openapi" && body.api_key !== undefined) throw invalidRequest("api_key is accepted only for api key apps");
    // Composio's user_id must stay the same opaque member uuid for the life of the connection (ADR 0033), so a
    // Composio connection always belongs to one member.
    if (!body.personal && entry.method === "composio") throw invalidRequest("a Composio connection must be personal");
    if (!body.personal && !seesAll(p)) throw new ApiError(403, "forbidden", "only an owner or admin adds a workspace connection");

    const idemKey = c.req.header("idempotency-key");
    if (idemKey !== undefined && !ULID_RE.test(idemKey)) throw invalidRequest("Idempotency-Key must be a ULID");
    const { api_key: apiKey, ...rest } = body;
    const requestSha256 = sha256Hex(jcs({ ...rest, api_key_present: apiKey !== undefined }));

    const memberId = body.personal ? p.memberId : null;
    const composio = composioFor(entry, p.memberId);
    const connectionId = uuidv7();

    // tx1: the row (needs_reauth), the pending idempotency record and connection.created.
    const first = await withTenant(pool, ctxOf(p), async (tx) => {
      if (idemKey !== undefined) {
        const prior = (await tx.query<{ request_sha256: string; status: number; response: unknown; fresh: boolean }>(
          "select request_sha256, status, response, created_at > now() - interval '24 hours' as fresh from idempotency_keys where key = $1 for update",
          [idemKey],
        )).rows[0];
        if (prior && prior.fresh) {
          if (prior.request_sha256 !== requestSha256 || prior.status === 0) throw new ApiError(409, "idempotency_conflict", "Idempotency-Key already used");
          return { replay: { status: prior.status, response: prior.response } };
        }
        if (prior) await tx.query("delete from idempotency_keys where key = $1", [idemKey]);
        await tx.query("insert into idempotency_keys (tenant_id, key, request_sha256, status) values ($1, $2, $3, 0)", [p.tenantId, idemKey, requestSha256]);
      }
      // The workspace must be in this tenant (RLS) and the caller in it, unless the caller is an owner or admin.
      const ws = await tx.query(
        `select 1 from workspaces w where w.id = $1 and ($3::boolean or exists (
           select 1 from workspace_members m where m.workspace_id = w.id and m.member_id = $2))`,
        [body.workspace_id, p.memberId, seesAll(p)],
      );
      if ((ws.rowCount ?? 0) === 0) throw invalidRequest("no such workspace");
      const row = (await tx.query<ConnectionRow>(
        `insert into connections (tenant_id, id, workspace_id, member_id, adapter, provider, capabilities, state)
         values ($1, $2, $3, $4, $5, $6, $7, 'needs_reauth') returning ${COLUMNS}`,
        [p.tenantId, connectionId, body.workspace_id, memberId, entry.adapter, entry.provider, entry.capabilities],
      )).rows[0]!;
      await appendAudit(tx, {
        principalId: p.memberId, action: "connection.created", subjectType: "connection", subjectId: connectionId,
        details: { provider: entry.provider, adapter: entry.adapter, method: entry.method, personal: body.personal },
      });
      return { row };
    });
    if ("replay" in first) return c.json(first.replay.response as object, first.replay.status as 201);

    let out: ConnectionCreated;
    try {
      if (entry.method === "openapi") {
        const acct = await broker.putApiKey({ tenant_id: p.tenantId, connection_id: connectionId, api_key: apiKey! });
        const active = await withTenant(pool, ctxOf(p), async (tx) => {
          const row = (await tx.query<ConnectionRow>(
            `update connections set state = 'active', account_label = $2, account_hash = $3 where id = $1 returning ${COLUMNS}`,
            [connectionId, acct.account_label.slice(0, MAX_LABEL), acct.account_hash],
          )).rows[0]!;
          await appendAudit(tx, {
            principalId: p.memberId, action: "connection.activated", subjectType: "connection", subjectId: connectionId,
            details: { account_hash: acct.account_hash },
          });
          return row;
        });
        await pinTools(broker, p, active, undefined);
        out = ConnectionCreatedSchema.parse({ connection_id: connectionId });
      } else {
        const begun = await broker.oauthBegin({
          tenant_id: p.tenantId, connection_id: connectionId, provider: entry.provider, scopes: [...entry.scopes],
          redirect_uri: `${base}/v1/connections/callback`, ...(composio ? { composio } : {}),
        });
        out = ConnectionCreatedSchema.parse({ connection_id: connectionId, authorize_url: begun.authorize_url });
      }
    } catch (err) {
      // The key may be retried: drop the pending record (the connection stays needs_reauth).
      if (idemKey !== undefined) {
        await withTenant(pool, ctxOf(p), (tx) => tx.query("delete from idempotency_keys where key = $1 and status = 0", [idemKey])).catch(() => undefined);
      }
      throw err;
    }
    if (idemKey !== undefined) {
      await withTenant(pool, ctxOf(p), (tx) =>
        tx.query("update idempotency_keys set status = 201, response = $2 where key = $1", [idemKey, JSON.stringify(out)]));
    }
    c.header("cache-control", "no-store");
    return c.json(out, 201);
  });

  app.get("/v1/connections/callback", async (c) => {
    const broker = deps.broker;
    if (!broker) throw noBroker();
    const p = await deps.authenticate(c);
    const state = c.req.query("state") ?? "";
    const code = c.req.query("code") ?? "";
    if (!STATE_RE.test(state) || !STATE_RE.test(code)) throw invalidRequest("state and code are required");
    let finished;
    try {
      finished = await broker.oauthFinish({ tenant_id: p.tenantId, state, code });
    } catch {
      throw invalidRequest("the authorization could not be finished");
    }
    if (!UUID_RE.test(finished.connection_id)) throw notFound();
    const conn = await withTenant(pool, ctxOf(p), async (tx) => {
      const found = await visible(tx, p, finished.connection_id, true);
      if (!found) throw notFound();
      if (found.state !== "needs_reauth") throw new ApiError(409, "state_conflict", "the connection is not waiting for authorization");
      const row = (await tx.query<ConnectionRow>(
        `update connections set state = 'active', account_label = $2, account_hash = $3 where id = $1 returning ${COLUMNS}`,
        [found.id, finished.account_label.slice(0, MAX_LABEL), finished.account_hash],
      )).rows[0]!;
      await appendAudit(tx, {
        principalId: p.memberId, action: "connection.activated", subjectType: "connection", subjectId: found.id,
        details: { account_hash: finished.account_hash },
      });
      return row;
    });
    const composio = conn.adapter === "composio" ? conn.member_id ? composioFor(findEntry(catalog, conn.provider), conn.member_id) : undefined : undefined;
    if (conn.adapter === "composio" && !composio) throw new ApiError(409, "state_conflict", "the app is no longer in the catalog");
    await pinTools(broker, p, conn, composio);
    c.header("cache-control", "no-store");
    return c.redirect(`${base}/connections?connection_id=${conn.id}`, 302);
  });

  app.get("/v1/connections/:id/tools", async (c) => {
    const p = await deps.authenticate(c);
    const id = c.req.param("id");
    if (!UUID_RE.test(id)) throw notFound();
    const pins = await withTenant(pool, ctxOf(p), async (tx) => {
      if (!(await visible(tx, p, id))) throw notFound();
      return (await tx.query<{ tool_name: string; pin_hash: string }>(
        "select tool_name, pin_hash from connection_tool_pins where connection_id = $1",
        [id],
      )).rows;
    });
    const tools = pins
      .map((r) => ({ name: r.tool_name, pin_hash: r.pin_hash }))
      .sort((a, b) => (a.name < b.name ? -1 : a.name > b.name ? 1 : 0));
    return c.json(ToolPinListSchema.parse({ tools }));
  });

  app.delete("/v1/connections/:id", async (c) => {
    const broker = deps.broker;
    if (!broker) throw noBroker();
    const p = await deps.authenticate(c);
    const id = c.req.param("id");
    if (!UUID_RE.test(id)) throw notFound();
    const found = await withTenant(pool, ctxOf(p), (tx) => visible(tx, p, id));
    if (!found) throw notFound();
    if (found.state === "revoked") return c.body(null, 204);
    await broker.shred({ tenant_id: p.tenantId, connection_id: id });
    await withTenant(pool, ctxOf(p), async (tx) => {
      const r = await tx.query("update connections set state = 'revoked' where id = $1 and state <> 'revoked'", [id]);
      if ((r.rowCount ?? 0) > 0) {
        await appendAudit(tx, { principalId: p.memberId, action: "connection.revoked", subjectType: "connection", subjectId: id, details: { via: p.via } });
      }
    });
    return c.body(null, 204);
  });
}
