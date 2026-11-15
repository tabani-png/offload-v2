import { expect } from "bun:test";
import { FakeClock, FakeMailer, deviceTokenSigningKey, fakeOidcIssuer, pgTenantFixture } from "@offload/testkit";
import { FakeBroker } from "@offload/testkit/src/connectors/index.ts";
import { launchCatalog } from "@offload/connectors-sdk";
import type { CatalogEntry } from "@offload/contracts/src/connections/index.ts";
import type { Hono } from "hono";
import { createApp, createOidcClient } from "../../src/index.ts";
import { BASE, session, type Harness } from "../m1-04-login-devices/harness.ts";

/**
 * Shared setup for the m2-02 route suite: real Postgres 17 (offload_app pool), the m1-04 fake OIDC issuer for logins,
 * and the testkit FakeBroker. Two apps share one database:
 * - `app` gets a test catalog where every launch entry is marked verified in spike S5 (create flows need that);
 * - `launchApp` gets the shipped launch catalog (every entry unverified) and its own FakeBroker.
 */

export { BASE, session, user } from "../m1-04-login-devices/harness.ts";

export const S5_DATE = "2026-11-01T00:00:00.000Z";
export const CALLBACK_URI = `${BASE}/v1/connections/callback`;

/** The shipped launch catalog with every entry marked verified. */
export const verifiedCatalog = (): CatalogEntry[] => launchCatalog().map((e) => ({ ...e, s5_verified_at: S5_DATE }));

type ReqInit = RequestInit & { cookie?: string; csrf?: string; bearer?: string; json?: unknown; app?: "verified" | "launch" };

export interface ConnHarness extends Harness {
  broker: FakeBroker;
  launchBroker: FakeBroker;
  catalog: CatalogEntry[];
  req(path: string, init?: ReqInit): Promise<Response>;
}

export async function makeHarness(): Promise<ConnHarness> {
  const fx = await pgTenantFixture();
  const clock = new FakeClock("2026-11-14T09:00:00.000Z");
  const issuer = await fakeOidcIssuer({ now: () => clock.now() });
  const mailer = new FakeMailer();
  const signingKey = deviceTokenSigningKey();
  const broker = new FakeBroker();
  const launchBroker = new FakeBroker();
  const catalog = verifiedCatalog();
  const build = (b: FakeBroker, cat: CatalogEntry[]): Hono =>
    createApp({
      pool: fx.app,
      publicBaseUrl: BASE,
      clock,
      oidc: createOidcClient({
        issuer: issuer.issuer, clientId: issuer.clientId, clientSecret: issuer.clientSecret,
        redirectUri: `${BASE}/auth/callback`, fetch: issuer.fetch, clock,
      }),
      mailer,
      deviceTokenSigningKeyPem: signingKey.pkcs8Pem,
      broker: b,
      catalog: cat,
    });
  const apps = { verified: build(broker, catalog), launch: build(launchBroker, launchCatalog()) };
  return {
    fx, clock, issuer, mailer, signingKey, broker, launchBroker, catalog,
    req: async (path, init = {}) => {
      const { cookie, csrf, bearer, json, app, ...rest } = init;
      const headers = new Headers(rest.headers);
      if (cookie) headers.set("cookie", cookie);
      if (csrf) headers.set("x-csrf-token", csrf);
      if (bearer) headers.set("authorization", `Bearer ${bearer}`);
      let body = rest.body;
      if (json !== undefined) {
        headers.set("content-type", "application/json");
        body = JSON.stringify(json);
      }
      return apps[app ?? "verified"].request(path.startsWith("http") ? path : `${BASE}${path}`, { ...rest, headers, body: body ?? null });
    },
    close: () => fx.close(),
  };
}

export type Session = Awaited<ReturnType<typeof session>>;

/** The caller's personal tenant, workspace and member ids from GET /v1/me. */
export const ids = (s: Session) => ({
  tenantId: s.me.tenant.id as string,
  workspaceId: s.me.workspaces[0].id as string,
  memberId: s.me.member.id as string,
});

export async function createConnection(h: ConnHarness, s: Session, body: Record<string, unknown>, init: ReqInit = {}) {
  const res = await h.req("/v1/connections", {
    method: "POST", cookie: s.cookie, csrf: s.csrf,
    json: { workspace_id: ids(s).workspaceId, personal: true, ...body },
    ...init,
  });
  const text = await res.text();
  let json: any = null;
  try {
    json = JSON.parse(text);
  } catch {
    json = null;
  }
  return { res, text, body: json };
}

/** POST for an OAuth app, then the callback with the state taken from authorize_url. */
export async function connectOAuth(h: ConnHarness, s: Session, provider: string, adapter: string) {
  const created = await createConnection(h, s, { provider, adapter });
  expect(created.res.status).toBe(201);
  const connectionId = created.body.connection_id as string;
  const authorizeUrl = created.body.authorize_url as string;
  const state = new URL(authorizeUrl).searchParams.get("state")!;
  const q = new URLSearchParams({ state, code: `code-${connectionId}` });
  const callback = await h.req(`/v1/connections/callback?${q}`, { cookie: s.cookie });
  return { created, connectionId, authorizeUrl, state, callback };
}

export async function connectionRow(h: ConnHarness, id: string) {
  return (await h.fx.admin.query("select * from connections where id = $1", [id])).rows[0];
}

export async function auditActions(h: ConnHarness, tenantId: string, connectionId: string): Promise<string[]> {
  const r = await h.fx.admin.query(
    "select action from audit_events where tenant_id = $1 and subject_type = 'connection' and subject_id = $2 order by seq",
    [tenantId, connectionId],
  );
  return r.rows.map((x) => x.action as string);
}

export async function pinRows(h: ConnHarness, tenantId: string, connectionId: string): Promise<{ tool_name: string; pin_hash: string }[]> {
  const r = await h.fx.admin.query(
    "select tool_name, pin_hash from connection_tool_pins where tenant_id = $1 and connection_id = $2 order by tool_name",
    [tenantId, connectionId],
  );
  return r.rows;
}

export const callsOf = (b: FakeBroker, method: string) => b.calls.filter((c) => c.method === method);
