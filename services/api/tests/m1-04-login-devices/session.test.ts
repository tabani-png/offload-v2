import { afterAll, beforeAll, expect, test } from "bun:test";
import { BASE, cookieFrom, login, me, session, sha256Hex, user, type Harness, makeHarness } from "./harness.ts";

let h: Harness;
beforeAll(async () => {
  h = await makeHarness();
});
afterAll(async () => {
  await h.close();
});

test("SESSION: first login creates a personal tenant with the member as owner", async () => {
  const u = user("first");
  const s = await login(h, u, "/today");
  expect(s.location).toBe("/today");
  const m = await me(h, { cookie: s.cookie });
  expect(m.status).toBe(200);
  expect(m.body.tenant_role).toBe("owner");
  expect(m.body.tenant.kind).toBe("personal");
  expect(m.body.member.email).toBe(u.email);
  expect(m.body.workspaces).toHaveLength(1);
  expect(Array.isArray(m.body.features)).toBe(true);
  const rows = (await h.fx.admin.query("select tenant_id, tenant_role, state from members where tenant_id = $1", [m.body.tenant.id])).rows;
  expect(rows).toEqual([{ tenant_id: m.body.tenant.id, tenant_role: "owner", state: "active" }]);
  const audit = (await h.fx.admin.query("select action from audit_events where tenant_id = $1 order by seq", [m.body.tenant.id])).rows.map((r) => r.action);
  expect(audit).toEqual(["tenant.created", "member.logged_in"]);
});

test("SESSION: second login reuses the tenant", async () => {
  const u = user("again");
  const first = await me(h, { cookie: (await login(h, u)).cookie });
  const second = await me(h, { cookie: (await login(h, u)).cookie });
  expect(second.body.tenant.id).toBe(first.body.tenant.id);
  expect(second.body.member.id).toBe(first.body.member.id);
  const tenants = (await h.fx.admin.query("select count(*)::int as n from members where email = $1", [u.email])).rows[0].n;
  expect(tenants).toBe(1);
  const logins = (await h.fx.admin.query("select count(*)::int as n from audit_events where tenant_id = $1 and action = 'member.logged_in'", [first.body.tenant.id])).rows[0].n;
  expect(logins).toBe(2);
});

test("SESSION: cookie is __Host- prefixed, httpOnly, Secure, SameSite=Lax", async () => {
  const start = await h.req("/auth/login?return_to=/");
  const cb = h.issuer.authorize(start.headers.get("location")!, user("cookie"));
  const done = await h.req(cb, { cookie: cookieFrom(start, "__Host-offload_login")! });
  const raw = done.headers.getSetCookie().find((c) => c.startsWith("__Host-offload_session="))!;
  expect(raw).toBeDefined();
  const attrs = raw.split(";").slice(1).map((a) => a.trim().toLowerCase());
  expect(attrs).toContain("httponly");
  expect(attrs).toContain("secure");
  expect(attrs).toContain("samesite=lax");
  expect(attrs).toContain("path=/");
  expect(attrs.some((a) => a.startsWith("domain="))).toBe(false);
  // 32 random bytes, base64url
  expect(raw.split(";")[0]!.split("=")[1]).toMatch(/^[A-Za-z0-9_-]{43}$/);
  // The session row stores only the hash.
  const token = raw.split(";")[0]!.split("=")[1]!;
  const stored = (await h.fx.admin.query("select count(*)::int as n from sessions where token_sha256 = $1", [sha256Hex(token)])).rows[0].n;
  expect(stored).toBe(1);
});

test("SESSION: a mutation without X-CSRF-Token is 403", async () => {
  const s = await session(h, user("csrf"));
  const missing = "0190d6c4-0000-7000-8000-000000000000";
  const none = await h.req(`/v1/devices/${missing}`, { method: "DELETE", cookie: s.cookie });
  expect(none.status).toBe(403);
  expect(((await none.json()) as any).error.code).toBe("forbidden");
  const wrong = await h.req(`/v1/devices/${missing}`, { method: "DELETE", cookie: s.cookie, csrf: "x".repeat(43) });
  expect(wrong.status).toBe(403);
  const right = await h.req(`/v1/devices/${missing}`, { method: "DELETE", cookie: s.cookie, csrf: s.csrf });
  expect(right.status).toBe(404);
  expect(((await right.json()) as any).error.code).toBe("not_found");
});

test("SESSION: GET /v1/me returns the csrf token once per session", async () => {
  const s = await login(h, user("once"));
  const first = await me(h, { cookie: s.cookie });
  expect(first.body.csrf_token).toMatch(/^[A-Za-z0-9_-]{43}$/);
  const second = await me(h, { cookie: s.cookie });
  expect(second.status).toBe(200);
  expect("csrf_token" in second.body).toBe(false);
  const row = (await h.fx.admin.query("select csrf_sha256 from sessions where token_sha256 = $1", [sha256Hex(s.sessionToken)])).rows[0];
  expect(row.csrf_sha256).toBe(sha256Hex(first.body.csrf_token));
  // A new session gets its own token.
  const other = await me(h, { cookie: (await login(h, user("once-b"))).cookie });
  expect(other.body.csrf_token).toMatch(/^[A-Za-z0-9_-]{43}$/);
  expect(other.body.csrf_token).not.toBe(first.body.csrf_token);
});

test("SESSION: an owner idle for 31 minutes on the web is 401 token_expired", async () => {
  const s = await session(h, user("idle"));
  expect(s.me.tenant_role).toBe("owner");
  h.clock.advanceMinutes(29);
  expect((await me(h, { cookie: s.cookie })).status).toBe(200); // activity slides the idle window
  h.clock.advanceMinutes(31);
  const r = await me(h, { cookie: s.cookie });
  expect(r.status).toBe(401);
  expect(r.body.error.code).toBe("token_expired");
});

test("SESSION: return_to that is not a same-origin path is 400", async () => {
  for (const bad of ["https://evil.example/", "//evil.example/x", "/\\evil.example", "evil", "javascript:alert(1)", `${BASE}/today`]) {
    const r = await h.req(`/auth/login?return_to=${encodeURIComponent(bad)}`);
    expect(r.status).toBe(400);
    expect(((await r.json()) as any).error.code).toBe("invalid_request");
  }
  const ok = await h.req(`/auth/login?return_to=${encodeURIComponent("/today?d=2026-11-14")}`);
  expect(ok.status).toBe(302);
  expect(new URL(ok.headers.get("location")!).origin).toBe(new URL(h.issuer.issuer).origin);
});

test("SESSION: a magic link works once and expires after 15 minutes", async () => {
  const email = user("magic").email;
  const sent = await h.req("/auth/magic-link", { method: "POST", json: { email } });
  expect(sent.status).toBe(204);
  const { url, to } = h.mailer.last();
  expect(to).toBe(email);
  expect(url.startsWith(`${BASE}/auth/magic-link/callback?`)).toBe(true);
  const token = new URL(url).searchParams.get("token")!;
  expect(token).toMatch(/^[A-Za-z0-9_-]{43}$/);
  const stored = (await h.fx.admin.query("select count(*)::int as n from magic_links where token_sha256 = $1", [sha256Hex(token)])).rows[0].n;
  expect(stored).toBe(1);

  const first = await h.req(url);
  expect(first.status).toBe(302);
  const cookie = cookieFrom(first, "__Host-offload_session")!;
  const m = await me(h, { cookie });
  expect(m.status).toBe(200);
  expect(m.body.tenant_role).toBe("owner");
  expect(m.body.member.email).toBe(email);

  const again = await h.req(url);
  expect(again.status).toBe(401);
  expect(cookieFrom(again, "__Host-offload_session")).toBeUndefined();

  // The same email logs in to the same tenant with a fresh link.
  await h.req("/auth/magic-link", { method: "POST", json: { email } });
  const second = await h.req(h.mailer.last().url);
  expect(second.status).toBe(302);
  expect((await me(h, { cookie: cookieFrom(second, "__Host-offload_session")! })).body.tenant.id).toBe(m.body.tenant.id);

  await h.req("/auth/magic-link", { method: "POST", json: { email } });
  const late = h.mailer.last().url;
  h.clock.advanceMinutes(16);
  const expired = await h.req(late);
  expect(expired.status).toBe(401);
  expect(((await expired.json()) as any).error.code).toBe("token_expired");
});

test("SESSION: logout needs X-CSRF-Token and revokes the session", async () => {
  const s = await session(h, user("logout"));
  const forced = await h.req("/auth/logout", { method: "POST", cookie: s.cookie });
  expect(forced.status).toBe(403);
  expect((await me(h, { cookie: s.cookie })).status).toBe(200);
  const out = await h.req("/auth/logout", { method: "POST", cookie: s.cookie, csrf: s.csrf });
  expect(out.status).toBe(204);
  expect(out.headers.getSetCookie().some((c) => c.startsWith("__Host-offload_session=;") && c.includes("Max-Age=0"))).toBe(true);
  const after = await me(h, { cookie: s.cookie });
  expect(after.status).toBe(401);
  expect(after.body.error.code).toBe("unauthenticated");
});

test("SESSION: a body over 16 KB is 413 and a magic link request must be JSON", async () => {
  const big = await h.req("/auth/magic-link", { method: "POST", json: { email: `${"a".repeat(20_000)}@example.test` } });
  expect(big.status).toBe(413);
  expect(((await big.json()) as any).error.code).toBe("too_large");
  const sent = h.mailer.sent.length;
  const form = await h.req("/auth/magic-link", { method: "POST", headers: { "content-type": "text/plain" }, body: JSON.stringify({ email: "x@example.test" }) });
  expect(form.status).toBe(400);
  expect(((await form.json()) as any).error.code).toBe("invalid_request");
  expect(h.mailer.sent.length).toBe(sent);
});
