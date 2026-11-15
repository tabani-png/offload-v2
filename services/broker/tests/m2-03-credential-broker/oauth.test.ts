import { afterAll, beforeAll, expect, test } from "bun:test";
import { createHash } from "node:crypto";
import { sha256Hex } from "@offload/contracts";
import { uuidv7 } from "@offload/db";
import { CLIENT_SECRET, auditActions, connect, connectionState, credentialRow, setup, type Env } from "./harness.ts";

let env: Env;
beforeAll(async () => {
  env = await setup();
});
afterAll(async () => {
  await env.stop();
});

const REDIRECT = "https://app.example.test/oauth/callback";

async function begin(t = env.fx.a, conn?: string) {
  const connection = conn ?? (await connect(env, t, { provider: "google_sheets" }));
  const r = await env.call("/oauth/begin", {
    tenant_id: t.tenantId, member_id: t.owner, connection_id: connection, provider: "google_sheets",
    scopes: ["https://www.googleapis.com/auth/spreadsheets"], redirect_uri: REDIRECT,
  });
  return { r, connection };
}

const b64url = (b: Buffer) => b.toString("base64url");

test("OAUTH: begin returns an authorize_url with PKCE S256 and a single-use state", async () => {
  const { r, connection } = await begin();
  expect(r.status).toBe(200);
  expect(Object.keys(r.json)).toEqual(["authorize_url"]);
  const u = new URL(r.json.authorize_url);
  expect(`${u.origin}${u.pathname}`).toBe(env.oauth.authorizeUrl);
  const p = u.searchParams;
  expect(p.get("response_type")).toBe("code");
  expect(p.get("client_id")).toBe("test-client-id");
  expect(p.get("redirect_uri")).toBe(REDIRECT);
  expect(p.get("scope")).toBe("https://www.googleapis.com/auth/spreadsheets");
  expect(p.get("code_challenge_method")).toBe("S256");
  const state = p.get("state")!;
  expect(Buffer.from(state, "base64url").length).toBe(32);
  expect(r.text.includes(CLIENT_SECRET)).toBe(false);
  const rows = (await env.fx.admin.query("select * from oauth_requests where tenant_id = $1 and connection_id = $2", [env.fx.a.tenantId, connection])).rows;
  expect(rows.length).toBe(1);
  expect(rows[0].state_sha256).toBe(sha256Hex(state)); // only the hash of the state is stored
  expect(JSON.stringify(rows[0]).includes(state)).toBe(false);
  expect(rows[0].used_at).toBeNull();
  expect(p.get("code_challenge")).toBe(b64url(createHash("sha256").update(rows[0].code_verifier).digest()));
  expect(new Date(rows[0].expires_at).getTime() - env.clock.now().getTime()).toBe(10 * 60_000);
  // Two begins never share a state or verifier.
  const second = await begin(env.fx.a, connection);
  expect(new URL(second.r.json.authorize_url).searchParams.get("state")).not.toBe(state);
});

test("OAUTH: finish with a used or expired state is refused and stores nothing", async () => {
  const stateOf = (r: { json: { authorize_url: string } }) => new URL(r.json.authorize_url).searchParams.get("state")!;
  // Expired: 10 minutes on the fake clock.
  const e = await begin();
  env.clock.advance(10 * 60_000 + 1000);
  const tokensBefore = env.oauth.tokenCalls.length;
  const late = await env.call("/oauth/finish", { tenant_id: env.fx.a.tenantId, state: stateOf(e.r), code: "code-1" });
  expect(late.status).toBe(400);
  expect(await credentialRow(env, env.fx.a, e.connection)).toBeUndefined();
  expect(await connectionState(env, env.fx.a, e.connection)).toBe("needs_reauth");
  expect(env.oauth.tokenCalls.length).toBe(tokensBefore);
  // Used: a second finish with the same state does nothing.
  const u = await begin();
  const first = await env.call("/oauth/finish", { tenant_id: env.fx.a.tenantId, state: stateOf(u.r), code: "code-2" });
  expect(first.status).toBe(200);
  const rowBefore = await credentialRow(env, env.fx.a, u.connection);
  const again = await env.call("/oauth/finish", { tenant_id: env.fx.a.tenantId, state: stateOf(u.r), code: "code-3" });
  expect(again.status).toBe(400);
  expect(env.oauth.tokenCalls.length).toBe(tokensBefore + 1);
  expect((await credentialRow(env, env.fx.a, u.connection)).ciphertext.equals(rowBefore.ciphertext)).toBe(true);
  // Unknown state and another tenant's state.
  expect((await env.call("/oauth/finish", { tenant_id: env.fx.a.tenantId, state: b64url(Buffer.alloc(32, 7)), code: "c" })).status).toBe(400);
  const o = await begin();
  const cross = await env.call("/oauth/finish", { tenant_id: env.fx.b.tenantId, state: stateOf(o.r), code: "c" });
  expect(cross.status).toBe(400);
  expect(env.oauth.tokenCalls.length).toBe(tokensBefore + 1);
  void uuidv7;
});

test("OAUTH: finish exchanges the code with the client secret inside the broker and stores the tokens encrypted", async () => {
  const { r, connection } = await begin();
  const u = new URL(r.json.authorize_url);
  const state = u.searchParams.get("state")!;
  const verifier = (await env.fx.admin.query("select code_verifier from oauth_requests where state_sha256 = $1", [sha256Hex(state)])).rows[0].code_verifier;
  const done = await env.call("/oauth/finish", { tenant_id: env.fx.a.tenantId, state, code: "auth-code-xyz" });
  expect(done.status).toBe(200);
  expect(done.json).toEqual({
    connection_id: connection, account_label: env.oauth.account.email, account_hash: sha256Hex(env.oauth.account.sub),
    scopes: ["https://www.googleapis.com/auth/spreadsheets"],
  });
  const call = env.oauth.tokenCalls.at(-1)!;
  expect(call.form).toMatchObject({
    grant_type: "authorization_code", code: "auth-code-xyz", client_id: "test-client-id", client_secret: CLIENT_SECRET,
    code_verifier: verifier, redirect_uri: REDIRECT,
  });
  const access = env.oauth.accessToken(env.oauth.tokenCalls.length);
  expect(done.text.includes(access)).toBe(false);
  expect(done.text.includes(env.oauth.refreshToken)).toBe(false);
  expect(await connectionState(env, env.fx.a, connection)).toBe("active");
  const row = await credentialRow(env, env.fx.a, connection);
  for (const needle of [access, env.oauth.refreshToken]) expect((row.ciphertext as Buffer).includes(Buffer.from(needle))).toBe(false);
  expect(row.refresh_state).toBe("ok");
  expect(row.scopes).toEqual(["https://www.googleapis.com/auth/spreadsheets"]);
  expect((await env.broker.vault.get(env.fx.a.tenantId, connection)).secret).toEqual({ kind: "oauth", access_token: access, refresh_token: env.oauth.refreshToken });
  expect((await auditActions(env, env.fx.a)).some((a) => a.action === "credential.stored" && a.details.connection_id === connection)).toBe(true);
  expect(JSON.stringify(env.logs).includes(CLIENT_SECRET)).toBe(false);
});
