import { afterAll, beforeAll, expect, test } from "bun:test";
import { deviceKey, onBeforeCommit } from "@offload/testkit";
import { LOOPBACK, authorize, cookieFrom, enroll, session, token, user, type Harness, makeHarness } from "./harness.ts";

let h: Harness;
beforeAll(async () => {
  h = await makeHarness();
});
afterAll(async () => {
  await h?.close(); // beforeAll may have failed before h was set: report that failure, not a TypeError here
});

test("AUDIT: device.enrolled is written in the same transaction", async () => {
  const s = await session(h, user("audit-tx"));
  const tenantId = s.me.tenant.id;
  const a = await authorize(h, s.cookie);
  const key = await deviceKey();
  const body = { code: a.code, code_verifier: a.pkce.verifier, redirect_uri: LOOPBACK, public_jwk: key.publicJwk, name: "Rollback Mac", key_storage: "keychain" };
  const remove = onBeforeCommit(async (tx) => {
    const r = await tx.query("select 1 from devices where name = 'Rollback Mac'");
    if ((r.rowCount ?? 0) > 0) throw new Error("injected commit failure");
  });
  let res: Response;
  try {
    res = await h.req("/v1/devices/enroll", { method: "POST", json: body });
  } finally {
    remove();
  }
  expect(res.status).toBe(500);
  expect(((await res.json()) as any).error.code).toBe("server_error");
  expect((await h.fx.admin.query("select count(*)::int as n from devices where tenant_id = $1", [tenantId])).rows[0].n).toBe(0);
  expect((await h.fx.admin.query("select count(*)::int as n from audit_events where tenant_id = $1 and action = 'device.enrolled'", [tenantId])).rows[0].n).toBe(0);
  // The code claim rolled back with them, so the same code still enrolls once.
  const retry = await h.req("/v1/devices/enroll", { method: "POST", json: body });
  expect(retry.status).toBe(200);
  const deviceId = ((await retry.json()) as any).device_id;
  const audit = (await h.fx.admin.query("select principal_id, subject_type, subject_id from audit_events where tenant_id = $1 and action = 'device.enrolled'", [tenantId])).rows;
  expect(audit).toEqual([{ principal_id: s.me.member.id, subject_type: "device", subject_id: deviceId }]);
});

test("AUDIT: no token or secret value appears in audit details", async () => {
  const secrets: string[] = [];
  const s = await session(h, user("audit-secrets"));
  secrets.push(s.sessionToken, s.csrf);
  const e = await enroll(h, s.cookie);
  secrets.push(e.code, e.verifier);
  for (const aud of ["device", "member"] as const) {
    const t = await token(h, e.deviceId, e.key, aud);
    expect(t.res.status).toBe(200);
    secrets.push(t.nonce, t.signature, t.body.token);
  }
  const del = await h.req(`/v1/devices/${e.deviceId}`, { method: "DELETE", cookie: s.cookie, csrf: s.csrf });
  expect(del.status).toBe(204);

  const email = user("audit-magic").email;
  await h.req("/auth/magic-link", { method: "POST", json: { email } });
  const link = h.mailer.last().url;
  const magicToken = new URL(link).searchParams.get("token")!;
  const ml = await h.req(link);
  expect(ml.status).toBe(302);
  secrets.push(magicToken, cookieFrom(ml, "__Host-offload_session")!.split("=")[1]!, email, h.issuer.clientSecret);

  const rows = (await h.fx.admin.query("select action, principal_id, subject_type, subject_id, rule_id, details from audit_events")).rows;
  const actions = new Set(rows.map((r) => r.action));
  for (const a of ["member.logged_in", "device.enrolled", "device.revoked"]) expect(actions.has(a)).toBe(true);
  const dump = JSON.stringify(rows);
  for (const v of secrets) {
    expect(v.length).toBeGreaterThan(8);
    expect(dump.includes(v)).toBe(false);
  }
  // Nor their unpadded halves (no partial copies either).
  for (const v of secrets.filter((x) => x.length >= 40)) expect(dump.includes(v.slice(0, 20))).toBe(false);
});
