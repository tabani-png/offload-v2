import { afterAll, beforeAll, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { decodeProtectedHeader, importJWK, jwtVerify } from "jose";
import { isCanonicalBody, parseOffloadSignature, verifyDeviceSignature } from "../../src/index.ts";
import { challenge, enroll, me, session, token, user, type Harness, makeHarness } from "./harness.ts";

let h: Harness;
let s: Awaited<ReturnType<typeof session>>;
beforeAll(async () => {
  h = await makeHarness();
  s = await session(h, user("token"));
});
afterAll(async () => {
  await h.close();
});

test("TOKEN: signed nonce returns a 15-minute ES256 token", async () => {
  const e = await enroll(h, s.cookie);
  const c = await challenge(h, e.deviceId, "device");
  expect(c.res.status).toBe(200);
  expect(c.body.nonce).toMatch(/^[A-Za-z0-9_-]{43}$/);
  expect(new Date(c.body.expires_at).getTime() - h.clock.now().getTime()).toBe(2 * 60_000);
  const nonceRow = (await h.fx.admin.query("select audience from device_nonces where device_id = $1 and nonce = $2", [e.deviceId, c.body.nonce])).rows[0];
  expect(nonceRow.audience).toBe("device");

  const signature = await e.key.sign(c.body.nonce);
  const res = await h.req("/v1/devices/token", { method: "POST", json: { device_id: e.deviceId, nonce: c.body.nonce, signature } });
  expect(res.status).toBe(200);
  const body = (await res.json()) as any;
  expect(decodeProtectedHeader(body.token).alg).toBe("ES256");
  const pub = await importJWK(h.signingKey.publicJwk as any, "ES256");
  const { payload } = await jwtVerify(body.token, pub, { audience: "device", currentDate: h.clock.now() });
  expect(payload.aud).toBe("device");
  expect(payload.exp! - payload.iat!).toBe(15 * 60);
  expect(payload.exp! * 1000).toBe(h.clock.now().getTime() + 15 * 60_000);
  expect(new Date(body.expires_at).getTime()).toBe(payload.exp! * 1000);
  expect(payload["tenant_id"]).toBe(s.me.tenant.id);
  expect(payload["member_id"]).toBe(s.me.member.id);
  expect(payload["device_id"]).toBe(e.deviceId);

  const m = await token(h, e.deviceId, e.key, "member");
  expect(m.res.status).toBe(200);
  expect((await jwtVerify(m.body.token, pub, { audience: "member", currentDate: h.clock.now() })).payload.aud).toBe("member");
});

test("TOKEN: a reused nonce is 409 nonce_used", async () => {
  const e = await enroll(h, s.cookie);
  const t = await token(h, e.deviceId, e.key, "device");
  expect(t.res.status).toBe(200);
  const again = await h.req("/v1/devices/token", { method: "POST", json: { device_id: e.deviceId, nonce: t.nonce, signature: t.signature } });
  expect(again.status).toBe(409);
  expect(((await again.json()) as any).error.code).toBe("nonce_used");
});

test("TOKEN: an expired nonce is 401 token_expired", async () => {
  const e = await enroll(h, s.cookie);
  const c = await challenge(h, e.deviceId, "device");
  h.clock.advance(2 * 60_000 + 1000);
  const res = await h.req("/v1/devices/token", { method: "POST", json: { device_id: e.deviceId, nonce: c.body.nonce, signature: await e.key.sign(c.body.nonce) } });
  expect(res.status).toBe(401);
  expect(((await res.json()) as any).error.code).toBe("token_expired");
});

test("TOKEN: a revoked device cannot get a token", async () => {
  const e = await enroll(h, s.cookie);
  const before = await token(h, e.deviceId, e.key, "member");
  expect(before.res.status).toBe(200);
  const pending = await challenge(h, e.deviceId, "device");
  const del = await h.req(`/v1/devices/${e.deviceId}`, { method: "DELETE", cookie: s.cookie, csrf: s.csrf });
  expect(del.status).toBe(204);
  const res = await h.req("/v1/devices/token", { method: "POST", json: { device_id: e.deviceId, nonce: pending.body.nonce, signature: await e.key.sign(pending.body.nonce) } });
  expect(res.status).toBe(401);
  expect(((await res.json()) as any).error.code).toBe("unauthenticated");
  const c = await challenge(h, e.deviceId, "device");
  expect(c.res.status).toBe(401);
  expect(c.body.error.code).toBe("unauthenticated");
  // A token minted before revocation fails on its next use.
  const used = await me(h, { bearer: before.body.token });
  expect(used.status).toBe(401);
  expect(used.body.error.code).toBe("unauthenticated");
});

test("TOKEN: a member-audience token authenticates GET /v1/me without a cookie", async () => {
  const e = await enroll(h, s.cookie);
  const t = await token(h, e.deviceId, e.key, "member");
  const m = await me(h, { bearer: t.body.token });
  expect(m.status).toBe(200);
  expect(m.body.member.id).toBe(s.me.member.id);
  expect(m.body.tenant.id).toBe(s.me.tenant.id);
  expect(m.body.tenant_role).toBe("owner");
  expect("csrf_token" in m.body).toBe(false);
  // A member token needs no CSRF header for mutations, and has no idle timeout.
  h.clock.advanceMinutes(14);
  const del = await h.req(`/v1/devices/0190d6c4-0000-7000-8000-000000000000`, { method: "DELETE", bearer: t.body.token });
  expect(del.status).toBe(404);
  // A device-audience token is not a member credential.
  const d = await token(h, e.deviceId, e.key, "device");
  const denied = await me(h, { bearer: d.body.token });
  expect(denied.status).toBe(401);
  expect(denied.body.error.code).toBe("unauthenticated");
  // An expired member token is token_expired.
  h.clock.advanceMinutes(16);
  const late = await me(h, { bearer: t.body.token });
  expect(late.status).toBe(401);
  expect(late.body.error.code).toBe("token_expired");
});

test("TOKEN: a DER-encoded signature is rejected and raw r‖s is accepted", async () => {
  const fixture = JSON.parse(readFileSync(join(import.meta.dir, "fixtures/swift-raw-signature.json"), "utf8"));
  const msg = new TextEncoder().encode(fixture.message);
  expect(await verifyDeviceSignature(fixture.public_jwk, msg, fixture.signature_raw)).toBe(true);
  expect(await verifyDeviceSignature(fixture.public_jwk, msg, fixture.signature_der)).toBe(false);
  expect(await verifyDeviceSignature(fixture.public_jwk, msg, `${fixture.signature_raw}=`)).toBe(false);
  expect(await verifyDeviceSignature(fixture.public_jwk, new TextEncoder().encode(`${fixture.message}x`), fixture.signature_raw)).toBe(false);

  const fresh = await session(h, user("der")); // the earlier session went idle while the clock moved
  const e = await enroll(h, fresh.cookie);
  const c = await challenge(h, e.deviceId, "device");
  const der = await h.req("/v1/devices/token", { method: "POST", json: { device_id: e.deviceId, nonce: c.body.nonce, signature: await e.key.signDer(c.body.nonce) } });
  expect(der.status).toBe(401);
  expect(((await der.json()) as any).error.code).toBe("unauthenticated");
  // A refused signature does not burn the nonce.
  const raw = await h.req("/v1/devices/token", { method: "POST", json: { device_id: e.deviceId, nonce: c.body.nonce, signature: await e.key.sign(c.body.nonce) } });
  expect(raw.status).toBe(200);
});

test("TOKEN: Offload-Signature parses keyid and sig, and a signed body must be JCS", async () => {
  expect(parseOffloadSignature("keyid=0190d6c4-0000-7000-8000-000000000000, sig=AAAA_-")).toEqual({ keyid: "0190d6c4-0000-7000-8000-000000000000", sig: "AAAA_-" });
  expect(parseOffloadSignature("keyid=not-a-uuid, sig=AAAA")).toBeNull();
  expect(parseOffloadSignature("sig=AAAA")).toBeNull();
  expect(isCanonicalBody('{"a":1,"b":[true,null]}')).toBe(true);
  expect(isCanonicalBody('{"b":1,"a":2}')).toBe(false);
  expect(isCanonicalBody('{"a": 1}')).toBe(false);
  expect(isCanonicalBody("{not json")).toBe(false);
});
