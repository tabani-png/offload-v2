import { Hono, type Context } from "hono";
import { bodyLimit } from "hono/body-limit";
import type { Pool } from "pg";
import {
  DeviceChallengeRequestSchema, DeviceEnrollRequestSchema, DeviceTokenRequestSchema, MagicLinkRequestSchema, token32,
  type MeResponse,
} from "@offload/contracts";
import {
  appendAudit, claimEnrollmentCode, countOpenNonces, claimMagicLink, claimNonce, createPersonalTenant, emailHash, getDevice, getNonce,
  insertDevice, insertEnrollmentCode, insertMagicLink, insertNonce, insertSession, issueCsrfOnce, listDevices, loadMe,
  memberRole, resolveDevice, resolveEnrollmentCode, resolveIdentity, resolveSession, revokeDevice, revokeSession,
  touchSession, uuidv7, withTenant, withTransaction, type TenantContext, type Tx,
} from "@offload/db";
import { calculateJwkThumbprint } from "jose";
import { ApiError, errorResponse, invalidRequest, toApiError, tokenExpired, unauthenticated } from "./http.ts";
import { systemClock, type Clock } from "./clock.ts";
import { random32, s256, safeEqual, sha256Hex } from "./auth/crypto.ts";
import { deviceTokenIssuer } from "./auth/device-token.ts";
import { OidcError, type OidcClient } from "./auth/oidc.ts";
import { parseP256PublicJwk, verifyDeviceSignature } from "./auth/signature.ts";
import {
  LOGIN_COOKIE, LOGIN_TTL_MS, MAGIC_LINK_TTL_MS, SESSION_ABSOLUTE_MS, SESSION_COOKIE, clearCookie, decodeLoginState,
  encodeLoginState, hostCookie, idleTimeoutMs, isLoopbackRedirect, readCookie, safeReturnTo,
} from "./auth/web.ts";

/**
 * The HTTP edge for M1: login (one OIDC provider or a magic link), web sessions, device enrollment (loopback PKCE)
 * and device tokens (ADR 0014, docs/API.md "Auth and me" and "Devices"). Raw tokens are never stored, logged or
 * audited: rows hold sha256 hex, audit details hold ids.
 */

export interface Mailer {
  /** Sends the sign-in link to `to`. Network I/O: called outside every transaction. */
  sendMagicLink(to: string, url: string): Promise<void>;
}

export interface AppDeps {
  /** Pool connected as offload_app. */
  pool: Pool;
  /** OFFLOAD_PUBLIC_BASE_URL, for example https://offload.example.com (no trailing slash). */
  publicBaseUrl: string;
  /** PKCS#8 PEM of the ES256 device-token key (resolved from OFFLOAD_DEVICE_TOKEN_SIGNING_KEY_REF). */
  deviceTokenSigningKeyPem: string;
  /** Absent: /auth/login and /auth/callback are 404 (magic link only). */
  oidc?: OidcClient;
  /** Absent: magic link routes are 404 (OIDC only). */
  mailer?: Mailer;
  clock?: Clock;
  /** Licensed features for GET /v1/me (core: none). */
  features?: () => string[];
}

type Role = "owner" | "admin" | "member" | "auditor";

interface Principal {
  tenantId: string;
  memberId: string;
  tenantRole: Role;
  via: "session" | "member_token";
  session?: { id: string; tokenSha256: string; csrfSha256: string };
}

const SAFE_METHODS = new Set(["GET", "HEAD", "OPTIONS"]);
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const MAX_BODY_BYTES = 16 * 1024;
const CHALLENGE_TTL_MS = 2 * 60_000;
const ENROLLMENT_CODE_TTL_MS = 10 * 60_000;
const STATE_RE = /^[\x21-\x7e]{1,512}$/;
/** Open (unused, unexpired) nonces one device may hold; more is 429 rate_limited. */
const MAX_OPEN_NONCES = 20;

const escapeHtml = (s: string) => s.replace(/[&<>"']/g, (ch) => `&#${ch.charCodeAt(0)};`).replace(/&#38;/g, "&amp;");

/** The csrf hash a session holds until GET /v1/me issues the real token: nobody knows a preimage of it. */
const unissuedCsrf = (tokenSha256: string) => sha256Hex(`offload:csrf-unissued:${tokenSha256}`);

const memberCtx = (tenantId: string, memberId: string, tenantRole: Role): TenantContext => ({ tenantId, principalId: memberId, memberId, tenantRole });

export function createApp(deps: AppDeps): Hono {
  const clock = deps.clock ?? systemClock;
  const base = deps.publicBaseUrl.replace(/\/+$/, "");
  const pool = deps.pool;
  const tokens = deviceTokenIssuer({ pkcs8Pem: deps.deviceTokenSigningKeyPem, issuer: base, clock });
  const app = new Hono();

  app.onError((err, c) => errorResponse(c, toApiError(err)));
  app.notFound((c) => errorResponse(c, new ApiError(404, "not_found", "no such route")));
  // Refuses large bodies before reading them (Content-Length, then while streaming).
  app.use("*", bodyLimit({ maxSize: MAX_BODY_BYTES, onError: (c) => errorResponse(c, new ApiError(413, "too_large", "body too large")) }));

  /** A member's role, read inside the tenant (null when the member is gone, frozen or departed). */
  const roleOf = (tenantId: string, memberId: string) =>
    withTenant(pool, memberCtx(tenantId, memberId, "member"), (tx) => memberRole(tx, memberId));

  async function jsonBody(c: Context): Promise<unknown> {
    // JSON only: a cross-site form or text/plain POST cannot reach these routes.
    const type = (c.req.header("content-type") ?? "").split(";")[0]!.trim().toLowerCase();
    if (type !== "application/json") throw invalidRequest("content-type must be application/json");
    const text = await c.req.text();
    if (Buffer.byteLength(text) > MAX_BODY_BYTES) throw new ApiError(413, "too_large", "body too large");
    try {
      return JSON.parse(text);
    } catch {
      throw invalidRequest("body is not JSON");
    }
  }

  // ---- authentication ------------------------------------------------------------------------------------------

  async function fromMemberToken(token: string): Promise<Principal> {
    const v = await tokens.verify(token, "member");
    if (!v.ok) throw new ApiError(401, v.code, v.code === "token_expired" ? "token expired" : "not a member token");
    const d = await resolveDevice(pool, v.claims.device_id);
    if (!d || d.revokedAt !== null || d.tenantId !== v.claims.tenant_id || d.memberId !== v.claims.member_id) throw unauthenticated("device revoked");
    const role = await roleOf(d.tenantId, d.memberId);
    if (!role) throw unauthenticated();
    return { tenantId: d.tenantId, memberId: d.memberId, tenantRole: role, via: "member_token" };
  }

  async function fromSessionCookie(raw: string): Promise<Principal> {
    if (!token32.safeParse(raw).success) throw unauthenticated();
    const tokenSha256 = sha256Hex(raw);
    const s = await resolveSession(pool, tokenSha256);
    if (!s) throw unauthenticated();
    const now = clock.now();
    if (s.expiresAt.getTime() <= now.getTime()) throw tokenExpired("session expired");
    if (now.getTime() - s.lastSeenAt.getTime() > idleTimeoutMs(s.tenantRole)) throw tokenExpired("session idle");
    const row = await withTenant(pool, memberCtx(s.tenantId, s.memberId, s.tenantRole), (tx) => touchSession(tx, tokenSha256, now));
    if (!row) throw unauthenticated();
    return { tenantId: s.tenantId, memberId: s.memberId, tenantRole: s.tenantRole, via: "session", session: { id: row.id, tokenSha256, csrfSha256: row.csrfSha256 } };
  }

  /** Member token (Authorization: Bearer, audience member) or web session cookie; CSRF on session mutations. */
  async function authenticate(c: Context): Promise<Principal> {
    const authz = c.req.header("authorization");
    if (authz !== undefined) {
      const m = /^Bearer ([A-Za-z0-9_.-]{1,4096})$/.exec(authz);
      if (!m) throw unauthenticated();
      return fromMemberToken(m[1]!);
    }
    const raw = readCookie(c.req.header("cookie"), SESSION_COOKIE);
    if (!raw) throw unauthenticated();
    const p = await fromSessionCookie(raw);
    if (!SAFE_METHODS.has(c.req.method)) {
      const header = c.req.header("x-csrf-token");
      if (!header || !safeEqual(sha256Hex(header), p.session!.csrfSha256)) throw new ApiError(403, "forbidden", "missing or wrong X-CSRF-Token");
    }
    return p;
  }

  // ---- login -----------------------------------------------------------------------------------------------------

  /** Finds or creates the member for an identity subject, opens a session and audits member.logged_in. */
  async function logIn(c: Context, subject: string, email: string | null, method: "oidc" | "magic_link", returnTo: string): Promise<Response> {
    let who = await resolveIdentity(pool, subject);
    if (!who) {
      if (!email) throw invalidRequest("unknown identity");
      try {
        const t = await withTransaction(pool, (tx) => createPersonalTenant(tx, { idpSubject: subject, email }));
        who = { tenantId: t.tenantId, memberId: t.memberId };
      } catch (err) {
        // Two first logins at once: the second loses the unique idp_subject and uses the first one's tenant.
        if ((err as { code?: string }).code !== "23505") throw err;
        who = await resolveIdentity(pool, subject);
        if (!who) throw err;
      }
    }
    const role = await roleOf(who.tenantId, who.memberId);
    if (!role) throw unauthenticated();
    const token = random32();
    const tokenSha256 = sha256Hex(token);
    const now = clock.now();
    const sessionId = uuidv7();
    await withTenant(pool, memberCtx(who.tenantId, who.memberId, role), async (tx) => {
      await insertSession(tx, {
        tenantId: who.tenantId, id: sessionId, memberId: who.memberId, tokenSha256, csrfSha256: unissuedCsrf(tokenSha256),
        now, expiresAt: new Date(now.getTime() + SESSION_ABSOLUTE_MS),
      });
      await appendAudit(tx, {
        principalId: who.memberId, action: "member.logged_in", subjectType: "member", subjectId: who.memberId,
        details: { method, session_id: sessionId },
      });
    });
    c.header("set-cookie", hostCookie(SESSION_COOKIE, token, SESSION_ABSOLUTE_MS / 1000), { append: true });
    c.header("cache-control", "no-store");
    return c.redirect(returnTo, 302);
  }

  app.get("/auth/login", async (c) => {
    if (!deps.oidc) throw new ApiError(404, "not_found", "OIDC login is not configured");
    const returnTo = safeReturnTo(c.req.query("return_to"), base);
    if (returnTo === null) throw invalidRequest("return_to must be a same-origin path");
    const state = random32();
    const nonce = random32();
    const verifier = random32();
    const url = await deps.oidc.authorizationUrl({ state, nonce, codeChallenge: s256(verifier) });
    const cookie = encodeLoginState({ state, nonce, verifier, return_to: returnTo, exp: clock.now().getTime() + LOGIN_TTL_MS });
    c.header("set-cookie", hostCookie(LOGIN_COOKIE, cookie, LOGIN_TTL_MS / 1000), { append: true });
    c.header("cache-control", "no-store");
    return c.redirect(url, 302);
  });

  app.get("/auth/callback", async (c) => {
    if (!deps.oidc) throw new ApiError(404, "not_found", "OIDC login is not configured");
    const login = decodeLoginState(readCookie(c.req.header("cookie"), LOGIN_COOKIE));
    c.header("set-cookie", clearCookie(LOGIN_COOKIE), { append: true });
    if (!login) throw invalidRequest("no login in progress");
    const state = c.req.query("state") ?? "";
    if (!safeEqual(state, login.state)) throw invalidRequest("state does not match");
    if (login.exp <= clock.now().getTime()) throw tokenExpired("login took too long");
    if (c.req.query("error") !== undefined) throw unauthenticated("the provider refused the login");
    const code = c.req.query("code");
    if (!code || code.length > 2048) throw invalidRequest("code is required");
    const returnTo = safeReturnTo(login.return_to, base);
    if (returnTo === null) throw invalidRequest("return_to must be a same-origin path");
    let identity;
    try {
      identity = await deps.oidc.exchange({ code, codeVerifier: login.verifier, nonce: login.nonce });
    } catch (err) {
      if (err instanceof OidcError) throw unauthenticated("the provider did not confirm the login");
      throw err;
    }
    return logIn(c, `oidc|${deps.oidc.issuer}|${identity.subject}`, identity.email, "oidc", returnTo);
  });

  app.post("/auth/logout", async (c) => {
    const raw = readCookie(c.req.header("cookie"), SESSION_COOKIE);
    if (raw && token32.safeParse(raw).success) {
      const tokenSha256 = sha256Hex(raw);
      const s = await resolveSession(pool, tokenSha256);
      if (s) {
        // A live session logs out only with its CSRF token (no forced logout from another site).
        await withTenant(pool, memberCtx(s.tenantId, s.memberId, s.tenantRole), async (tx) => {
          const row = (await tx.query<{ csrf_sha256: string }>("select csrf_sha256 from sessions where token_sha256 = $1", [tokenSha256])).rows[0];
          const header = c.req.header("x-csrf-token");
          if (!row || !header || !safeEqual(sha256Hex(header), row.csrf_sha256)) throw new ApiError(403, "forbidden", "missing or wrong X-CSRF-Token");
          await revokeSession(tx, tokenSha256, clock.now());
        });
      }
    }
    c.header("set-cookie", clearCookie(SESSION_COOKIE), { append: true });
    return c.body(null, 204);
  });

  app.post("/auth/magic-link", async (c) => {
    if (!deps.mailer) throw new ApiError(404, "not_found", "magic link login is not configured");
    const body = MagicLinkRequestSchema.safeParse(await jsonBody(c));
    if (!body.success) throw invalidRequest("email is required");
    const returnTo = safeReturnTo(body.data.return_to, base);
    if (returnTo === null) throw invalidRequest("return_to must be a same-origin path");
    const email = body.data.email.trim();
    const token = random32();
    await insertMagicLink(pool, {
      tokenSha256: sha256Hex(token), emailHash: emailHash(email), returnTo,
      expiresAt: new Date(clock.now().getTime() + MAGIC_LINK_TTL_MS),
    });
    // The email rides in the link so a first login can create the member: magic_links stores only its hash.
    const q = new URLSearchParams({ token, email });
    await deps.mailer.sendMagicLink(email, `${base}/auth/magic-link/callback?${q}`);
    return c.body(null, 204);
  });

  app.get("/auth/magic-link/callback", async (c) => {
    if (!deps.mailer) throw new ApiError(404, "not_found", "magic link login is not configured");
    const token = c.req.query("token") ?? "";
    if (!token32.safeParse(token).success) throw unauthenticated("invalid link");
    const claim = await claimMagicLink(pool, sha256Hex(token), clock.now());
    if (claim.status === "expired") throw tokenExpired("the link expired");
    if (claim.status !== "ok") throw unauthenticated("invalid or used link");
    const email = c.req.query("email");
    const matching = email !== undefined && safeEqual(emailHash(email), claim.emailHash) ? email.trim() : null;
    const returnTo = safeReturnTo(claim.returnTo, base) ?? "/";
    return logIn(c, `magic|${claim.emailHash}`, matching, "magic_link", returnTo);
  });

  // ---- me --------------------------------------------------------------------------------------------------------

  app.get("/v1/me", async (c) => {
    const p = await authenticate(c);
    const out = await withTenant(pool, memberCtx(p.tenantId, p.memberId, p.tenantRole), async (tx) => {
      const me = await loadMe(tx, p.memberId);
      if (!me) throw unauthenticated();
      let csrf: string | undefined;
      if (p.session) {
        const raw = random32();
        if (await issueCsrfOnce(tx, p.session.id, unissuedCsrf(p.session.tokenSha256), sha256Hex(raw))) csrf = raw;
      }
      return { me, csrf };
    });
    const body: MeResponse = {
      member: out.me.member, tenant: out.me.tenant, workspaces: out.me.workspaces, tenant_role: out.me.member.tenant_role,
      features: deps.features?.() ?? [],
      ...(out.csrf ? { csrf_token: out.csrf } : {}),
    };
    c.header("cache-control", "no-store");
    return c.json(body);
  });

  // ---- devices ---------------------------------------------------------------------------------------------------

  app.get("/v1/devices/authorize", async (c) => {
    let p: Principal;
    try {
      const raw = readCookie(c.req.header("cookie"), SESSION_COOKIE);
      if (!raw) throw unauthenticated();
      p = await fromSessionCookie(raw);
    } catch (err) {
      if (!(err instanceof ApiError) || err.status !== 401) throw err;
      const here = new URL(c.req.url);
      return c.redirect(`/auth/login?return_to=${encodeURIComponent(here.pathname + here.search)}`, 302);
    }
    const challenge = c.req.query("code_challenge") ?? "";
    const redirectUri = c.req.query("redirect_uri") ?? "";
    const state = c.req.query("state") ?? "";
    if (c.req.query("code_challenge_method") !== "S256") throw invalidRequest("code_challenge_method must be S256");
    if (!/^[A-Za-z0-9_-]{43}$/.test(challenge)) throw invalidRequest("code_challenge must be an S256 challenge");
    if (!isLoopbackRedirect(redirectUri)) throw invalidRequest("redirect_uri must be http://127.0.0.1:<port>/callback");
    if (!STATE_RE.test(state)) throw invalidRequest("state is required");
    // Only a navigation the person made (the Mac opening the browser: Sec-Fetch-Site none) or one from our own page
    // issues a code. Anything else, including a redirect chain from another site, gets a page to confirm first, so a
    // hostile page cannot enroll a key for a local listener without the person seeing it.
    const site = c.req.header("sec-fetch-site");
    if (site !== "none" && site !== "same-origin") {
      const here = new URL(c.req.url);
      const href = escapeHtml(here.pathname + here.search);
      c.header("x-frame-options", "DENY");
      c.header("content-security-policy", "default-src 'none'; frame-ancestors 'none'; form-action 'none'");
      c.header("cache-control", "no-store");
      return c.html(
        `<!doctype html><html lang="en"><head><meta charset="utf-8"><title>Connect this Mac</title></head><body>` +
        `<h1>Connect this Mac to your account?</h1><p>Only continue if you just started this on your Mac.</p>` +
        `<p><a href="${href}">Connect this Mac</a></p></body></html>`,
      );
    }
    const code = random32();
    await withTenant(pool, memberCtx(p.tenantId, p.memberId, p.tenantRole), (tx) =>
      insertEnrollmentCode(tx, {
        tenantId: p.tenantId, codeSha256: sha256Hex(code), memberId: p.memberId, codeChallenge: challenge, redirectUri,
        expiresAt: new Date(clock.now().getTime() + ENROLLMENT_CODE_TTL_MS),
      }));
    const to = new URL(redirectUri);
    to.search = new URLSearchParams({ code, state }).toString();
    c.header("cache-control", "no-store");
    return c.redirect(to.toString(), 302);
  });

  app.post("/v1/devices/enroll", async (c) => {
    const body = DeviceEnrollRequestSchema.safeParse(await jsonBody(c));
    if (!body.success) throw invalidRequest("invalid enrollment request");
    const b = body.data;
    const codeSha256 = sha256Hex(b.code);
    const code = await resolveEnrollmentCode(pool, codeSha256);
    const now = clock.now();
    // One answer for every refusal, so the code cannot be probed.
    const refuse = () => invalidRequest("invalid code, verifier, redirect_uri or key");
    if (!code || code.usedAt !== null || code.expiresAt.getTime() <= now.getTime()) throw refuse();
    if (!safeEqual(b.redirect_uri, code.redirectUri)) throw refuse();
    if (!safeEqual(s256(b.code_verifier), code.codeChallenge)) throw refuse();
    const jwk = await parseP256PublicJwk(b.public_jwk);
    if (!jwk) throw refuse();
    const role = await roleOf(code.tenantId, code.memberId);
    if (!role) throw refuse();
    const deviceId = uuidv7();
    const thumbprint = await calculateJwkThumbprint(jwk, "sha256");
    await withTenant(pool, memberCtx(code.tenantId, code.memberId, role), async (tx) => {
      if (!(await claimEnrollmentCode(tx, codeSha256, now))) throw refuse();
      await insertDevice(tx, { tenantId: code.tenantId, id: deviceId, memberId: code.memberId, publicJwk: jwk, keyStorage: b.key_storage, name: b.name, now });
      await appendAudit(tx, {
        principalId: code.memberId, action: "device.enrolled", subjectType: "device", subjectId: deviceId,
        details: { key_storage: b.key_storage, jwk_thumbprint: thumbprint },
      });
    });
    return c.json({ device_id: deviceId });
  });

  /** Resolves a device that may ask for nonces and tokens: known, not revoked, member active. */
  async function liveDevice(deviceId: string) {
    const d = await resolveDevice(pool, deviceId);
    if (!d || d.revokedAt !== null) throw unauthenticated("unknown or revoked device");
    const role = await roleOf(d.tenantId, d.memberId);
    if (!role) throw unauthenticated("unknown or revoked device");
    return { ...d, ctx: { tenantId: d.tenantId, principalId: deviceId, memberId: d.memberId, tenantRole: role } satisfies TenantContext };
  }

  app.post("/v1/devices/challenge", async (c) => {
    const body = DeviceChallengeRequestSchema.safeParse(await jsonBody(c));
    if (!body.success) throw invalidRequest("device_id and audience are required");
    const d = await liveDevice(body.data.device_id);
    const nonce = random32();
    const expiresAt = new Date(clock.now().getTime() + CHALLENGE_TTL_MS);
    await withTenant(pool, d.ctx, async (tx) => {
      if ((await countOpenNonces(tx, body.data.device_id, clock.now())) >= MAX_OPEN_NONCES) {
        const err = new ApiError(429, "rate_limited", "too many open challenges");
        err.retryAfterSeconds = CHALLENGE_TTL_MS / 1000;
        throw err;
      }
      await insertNonce(tx, { tenantId: d.tenantId, deviceId: body.data.device_id, nonce, audience: body.data.audience, expiresAt });
    });
    return c.json({ nonce, expires_at: expiresAt.toISOString() });
  });

  app.post("/v1/devices/token", async (c) => {
    const body = DeviceTokenRequestSchema.safeParse(await jsonBody(c));
    if (!body.success) throw invalidRequest("device_id, nonce and signature are required");
    const { device_id: deviceId, nonce, signature } = body.data;
    const d = await liveDevice(deviceId);
    const now = clock.now();
    const audience = await withTenant(pool, d.ctx, async (tx: Tx) => {
      const n = await getNonce(tx, deviceId, nonce);
      if (!n) throw unauthenticated("unknown nonce");
      if (n.usedAt !== null) throw new ApiError(409, "nonce_used", "nonce already used");
      if (n.expiresAt.getTime() <= now.getTime()) throw tokenExpired("nonce expired");
      const dev = await getDevice(tx, deviceId);
      if (!dev || dev.revoked_at !== null) throw unauthenticated("unknown or revoked device");
      if (!(await verifyDeviceSignature(dev.public_jwk, new TextEncoder().encode(nonce), signature))) throw unauthenticated("bad signature");
      if (!(await claimNonce(tx, deviceId, nonce, now))) throw new ApiError(409, "nonce_used", "nonce already used");
      return n.audience;
    });
    const t = await tokens.mint({ audience, tenantId: d.tenantId, memberId: d.memberId, deviceId });
    c.header("cache-control", "no-store");
    return c.json({ token: t.token, expires_at: t.expiresAt.toISOString() });
  });

  app.get("/v1/devices", async (c) => {
    const p = await authenticate(c);
    const all = p.tenantRole === "owner" || p.tenantRole === "admin";
    const rows = await withTenant(pool, memberCtx(p.tenantId, p.memberId, p.tenantRole), (tx) => listDevices(tx, all ? null : p.memberId));
    return c.json(rows.map((r) => ({
      id: r.id, member_id: r.member_id, name: r.name, key_storage: r.key_storage,
      enrolled_at: r.enrolled_at.toISOString(), revoked_at: r.revoked_at ? r.revoked_at.toISOString() : null,
    })));
  });

  app.delete("/v1/devices/:id", async (c) => {
    const p = await authenticate(c);
    const id = c.req.param("id");
    if (!UUID_RE.test(id)) throw new ApiError(404, "not_found", "no such device");
    await withTenant(pool, memberCtx(p.tenantId, p.memberId, p.tenantRole), async (tx) => {
      const dev = await getDevice(tx, id);
      const mayRevoke = dev && (dev.member_id === p.memberId || p.tenantRole === "owner" || p.tenantRole === "admin");
      if (!mayRevoke) throw new ApiError(404, "not_found", "no such device");
      if (await revokeDevice(tx, id, clock.now())) {
        await appendAudit(tx, { principalId: p.memberId, action: "device.revoked", subjectType: "device", subjectId: id, details: { via: p.via } });
      }
    });
    return c.body(null, 204);
  });

  return app;
}
