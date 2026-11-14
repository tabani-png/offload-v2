import { expect } from "bun:test";
import { createHash } from "node:crypto";
import {
  FakeClock, FakeMailer, deviceKey, deviceTokenSigningKey, fakeOidcIssuer, pgTenantFixture, pkcePair,
  type DeviceKey, type FakeOidcIssuer, type PgTenantFixture,
} from "@offload/testkit";
import { createApp, createOidcClient } from "../../src/index.ts";

/** Shared setup for the m1-04 suite: real Postgres (offload_app pool), a fake OIDC issuer, a fake clock and mailer. */

export const BASE = "https://offload.test";
export const LOOPBACK = "http://127.0.0.1:53123/callback";

export const sha256Hex = (s: string) => createHash("sha256").update(s).digest("hex");

export interface Harness {
  fx: PgTenantFixture;
  clock: FakeClock;
  issuer: FakeOidcIssuer;
  mailer: FakeMailer;
  signingKey: { pkcs8Pem: string; publicJwk: JsonWebKey };
  req(path: string, init?: RequestInit & { cookie?: string; csrf?: string; bearer?: string; json?: unknown }): Promise<Response>;
  close(): Promise<void>;
}

export async function makeHarness(): Promise<Harness> {
  const fx = await pgTenantFixture();
  const clock = new FakeClock("2026-11-14T09:00:00.000Z");
  const issuer = await fakeOidcIssuer({ now: () => clock.now() });
  const mailer = new FakeMailer();
  const signingKey = deviceTokenSigningKey();
  const app = createApp({
    pool: fx.app,
    publicBaseUrl: BASE,
    clock,
    oidc: createOidcClient({
      issuer: issuer.issuer, clientId: issuer.clientId, clientSecret: issuer.clientSecret,
      redirectUri: `${BASE}/auth/callback`, fetch: issuer.fetch, clock,
    }),
    mailer,
    deviceTokenSigningKeyPem: signingKey.pkcs8Pem,
  });
  return {
    fx, clock, issuer, mailer, signingKey,
    req: (path, init = {}) => {
      const { cookie, csrf, bearer, json, ...rest } = init;
      const headers = new Headers(rest.headers);
      if (cookie) headers.set("cookie", cookie);
      if (csrf) headers.set("x-csrf-token", csrf);
      if (bearer) headers.set("authorization", `Bearer ${bearer}`);
      let body = rest.body;
      if (json !== undefined) {
        headers.set("content-type", "application/json");
        body = JSON.stringify(json);
      }
      return app.request(path.startsWith("http") ? path : `${BASE}${path}`, { ...rest, headers, body: body ?? null });
    },
    close: () => fx.close(),
  };
}

/** `name=value` of a Set-Cookie header, or undefined. */
export function cookieFrom(res: Response, name: string): string | undefined {
  for (const c of res.headers.getSetCookie()) {
    const first = c.split(";")[0]!;
    if (first.startsWith(`${name}=`) && first.length > name.length + 1) return first;
  }
  return undefined;
}

export interface LoggedIn {
  cookie: string;
  /** Raw session token (the cookie value), for leak checks. */
  sessionToken: string;
  location: string;
}

/** Full OIDC login: /auth/login → fake provider → /auth/callback. */
export async function login(h: Harness, user: { subject: string; email: string }, returnTo = "/today"): Promise<LoggedIn> {
  const start = await h.req(`/auth/login?return_to=${encodeURIComponent(returnTo)}`);
  expect(start.status).toBe(302);
  const loginCookie = cookieFrom(start, "__Host-offload_login");
  expect(loginCookie).toBeDefined();
  const callback = h.issuer.authorize(start.headers.get("location")!, user);
  const done = await h.req(callback, { cookie: loginCookie! });
  expect(done.status).toBe(302);
  const cookie = cookieFrom(done, "__Host-offload_session");
  expect(cookie).toBeDefined();
  return { cookie: cookie!, sessionToken: cookie!.split("=")[1]!, location: done.headers.get("location")! };
}

export async function me(h: Harness, auth: { cookie?: string; bearer?: string }): Promise<{ status: number; body: any }> {
  const r = await h.req("/v1/me", auth);
  return { status: r.status, body: await r.json() };
}

/** Logs in and takes the csrf token from the first GET /v1/me. */
export async function session(h: Harness, user: { subject: string; email: string }) {
  const s = await login(h, user);
  const m = await me(h, { cookie: s.cookie });
  expect(m.status).toBe(200);
  return { ...s, csrf: m.body.csrf_token as string, me: m.body };
}

export async function authorize(h: Harness, cookie: string, redirectUri = LOOPBACK) {
  const pkce = pkcePair();
  const q = new URLSearchParams({ code_challenge: pkce.challenge, code_challenge_method: "S256", redirect_uri: redirectUri, state: "st-123" });
  const res = await h.req(`/v1/devices/authorize?${q}`, { cookie });
  const loc = res.headers.get("location");
  const code = loc ? new URL(loc).searchParams.get("code") ?? undefined : undefined;
  return { res, code, pkce };
}

export async function enroll(h: Harness, cookie: string, opts: { name?: string; key?: DeviceKey } = {}) {
  const a = await authorize(h, cookie);
  expect(a.res.status).toBe(302);
  const key = opts.key ?? (await deviceKey());
  const res = await h.req("/v1/devices/enroll", {
    method: "POST",
    json: { code: a.code, code_verifier: a.pkce.verifier, redirect_uri: LOOPBACK, public_jwk: key.publicJwk, name: opts.name ?? "Test Mac", key_storage: "secure_enclave" },
  });
  const body = (await res.json()) as any;
  return { res, deviceId: body.device_id as string, key, code: a.code!, verifier: a.pkce.verifier };
}

export async function challenge(h: Harness, deviceId: string, audience: "device" | "member") {
  const res = await h.req("/v1/devices/challenge", { method: "POST", json: { device_id: deviceId, audience } });
  return { res, body: (await res.json()) as any };
}

export async function token(h: Harness, deviceId: string, key: DeviceKey, audience: "device" | "member") {
  const c = await challenge(h, deviceId, audience);
  expect(c.res.status).toBe(200);
  const signature = await key.sign(c.body.nonce);
  const res = await h.req("/v1/devices/token", { method: "POST", json: { device_id: deviceId, nonce: c.body.nonce, signature } });
  return { res, body: (await res.json()) as any, nonce: c.body.nonce as string, signature };
}

let n = 0;
export const user = (label: string) => ({ subject: `sub-${label}-${Date.now()}-${n++}`, email: `${label}-${n}@example.test` });
