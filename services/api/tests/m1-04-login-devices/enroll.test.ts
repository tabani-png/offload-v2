import { afterAll, beforeAll, expect, test } from "bun:test";
import { generateKeyPairSync } from "node:crypto";
import { deviceKey } from "@offload/testkit";
import { LOOPBACK, authorize, enroll, session, sha256Hex, user, type Harness, makeHarness } from "./harness.ts";

let h: Harness;
let cookie: string;
let csrf: string;
let tenantId: string;
beforeAll(async () => {
  h = await makeHarness();
  const s = await session(h, user("enroll"));
  cookie = s.cookie;
  csrf = s.csrf;
  tenantId = s.me.tenant.id;
});
afterAll(async () => {
  await h.close();
});

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

async function post(body: Record<string, unknown>) {
  const res = await h.req("/v1/devices/enroll", { method: "POST", json: body });
  return { status: res.status, body: (await res.json()) as any };
}

test("ENROLL: authorize with a loopback redirect returns a code and state", async () => {
  const a = await authorize(h, cookie);
  expect(a.res.status).toBe(302);
  const loc = new URL(a.res.headers.get("location")!);
  expect(`${loc.origin}${loc.pathname}`).toBe(LOOPBACK);
  expect(loc.searchParams.get("state")).toBe("st-123");
  expect(a.code).toMatch(/^[A-Za-z0-9_-]{43}$/);
  const row = (await h.fx.admin.query(
    "select tenant_id, code_challenge, redirect_uri, used_at, expires_at - $2::timestamptz as ttl from device_enrollment_codes where code_sha256 = $1",
    [sha256Hex(a.code!), h.clock.now()],
  )).rows[0];
  expect(row.tenant_id).toBe(tenantId);
  expect(row.code_challenge).toBe(a.pkce.challenge);
  expect(row.redirect_uri).toBe(LOOPBACK);
  expect(row.used_at).toBeNull();
  expect(row.ttl.minutes).toBe(10);
  // Without a session the browser is sent to log in first, and comes back here.
  const anon = await h.req(`/v1/devices/authorize?${new URLSearchParams({ code_challenge: a.pkce.challenge, code_challenge_method: "S256", redirect_uri: LOOPBACK, state: "s" })}`);
  expect(anon.status).toBe(302);
  expect(anon.headers.get("location")!.startsWith("/auth/login?return_to=%2Fv1%2Fdevices%2Fauthorize")).toBe(true);
});

test("ENROLL: a non-loopback redirect_uri is 400", async () => {
  for (const bad of [
    "http://evil.example/callback", "http://localhost:53123/callback", "https://127.0.0.1:53123/callback",
    "http://127.0.0.1:80/callback", "http://127.0.0.1:70000/callback", "http://127.0.0.1:53123/other",
    "http://127.0.0.1:53123/callback?x=1", "http://user@127.0.0.1:53123/callback", "http://127.0.0.1/callback",
  ]) {
    const a = await authorize(h, cookie, bad);
    expect(a.res.status).toBe(400);
    expect(((await a.res.json()) as any).error.code).toBe("invalid_request");
  }
  const q = new URLSearchParams({ code_challenge: "abc", code_challenge_method: "plain", redirect_uri: LOOPBACK, state: "s" });
  expect((await h.req(`/v1/devices/authorize?${q}`, { cookie })).status).toBe(400);
});

test("ENROLL: PKCE S256 with loopback redirect returns a device id", async () => {
  const e = await enroll(h, cookie, { name: "Work Mac" });
  expect(e.res.status).toBe(200);
  expect(e.deviceId).toMatch(UUID);
  const row = (await h.fx.admin.query("select tenant_id, public_jwk, key_storage, name, revoked_at from devices where id = $1", [e.deviceId])).rows[0];
  expect(row.tenant_id).toBe(tenantId);
  expect(row.public_jwk).toEqual(e.key.publicJwk);
  expect(row.key_storage).toBe("secure_enclave");
  expect(row.revoked_at).toBeNull();
  const list = await h.req("/v1/devices", { cookie });
  expect(list.status).toBe(200);
  const devices = (await list.json()) as any[];
  expect(devices.map((d) => d.id)).toContain(e.deviceId);
  expect(devices.find((d) => d.id === e.deviceId)).toMatchObject({ name: "Work Mac", key_storage: "secure_enclave", revoked_at: null });
  void csrf;
});

test("ENROLL: a wrong code_verifier is 400", async () => {
  const a = await authorize(h, cookie);
  const key = await deviceKey();
  const r = await post({ code: a.code, code_verifier: "w".repeat(43), redirect_uri: LOOPBACK, public_jwk: key.publicJwk, name: "Mac", key_storage: "keychain" });
  expect(r.status).toBe(400);
  expect(r.body.error.code).toBe("invalid_request");
  expect((await h.fx.admin.query("select count(*)::int as n from devices where tenant_id = $1 and name = 'Mac'", [tenantId])).rows[0].n).toBe(0);
});

test("ENROLL: a redirect_uri different from the authorized one is 400", async () => {
  const a = await authorize(h, cookie);
  const key = await deviceKey();
  const r = await post({ code: a.code, code_verifier: a.pkce.verifier, redirect_uri: "http://127.0.0.1:53124/callback", public_jwk: key.publicJwk, name: "Mac", key_storage: "keychain" });
  expect(r.status).toBe(400);
  expect(r.body.error.code).toBe("invalid_request");
});

test("ENROLL: a public JWK that is not P-256 is 400", async () => {
  const p384 = generateKeyPairSync("ec", { namedCurve: "secp384r1" }).publicKey.export({ format: "jwk" });
  const rsa = generateKeyPairSync("rsa", { modulusLength: 2048 }).publicKey.export({ format: "jwk" });
  const withPrivate = generateKeyPairSync("ec", { namedCurve: "prime256v1" }).privateKey.export({ format: "jwk" });
  const offCurve = { kty: "EC", crv: "P-256", x: (await deviceKey()).publicJwk.x, y: (await deviceKey()).publicJwk.y };
  for (const jwk of [p384, rsa, withPrivate, offCurve, { kty: "EC", crv: "P-256", x: "abc", y: "def" }]) {
    const a = await authorize(h, cookie);
    const r = await post({ code: a.code, code_verifier: a.pkce.verifier, redirect_uri: LOOPBACK, public_jwk: jwk, name: "Mac", key_storage: "keychain" });
    expect(r.status).toBe(400);
    expect(r.body.error.code).toBe("invalid_request");
  }
});

test("ENROLL: an enrollment code works once and expires after 10 minutes", async () => {
  const e = await enroll(h, cookie);
  expect(e.res.status).toBe(200);
  const reuse = await post({ code: e.code, code_verifier: e.verifier, redirect_uri: LOOPBACK, public_jwk: e.key.publicJwk, name: "Again", key_storage: "keychain" });
  expect(reuse.status).toBe(400);
  expect(reuse.body.error.code).toBe("invalid_request");

  const a = await authorize(h, cookie);
  h.clock.advanceMinutes(11);
  const key = await deviceKey();
  const late = await post({ code: a.code, code_verifier: a.pkce.verifier, redirect_uri: LOOPBACK, public_jwk: key.publicJwk, name: "Late", key_storage: "keychain" });
  expect(late.status).toBe(400);
  expect(late.body.error.code).toBe("invalid_request");
  expect((await h.fx.admin.query("select count(*)::int as n from devices where name in ('Again', 'Late')")).rows[0].n).toBe(0);
});
