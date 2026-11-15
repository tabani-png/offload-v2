import { afterAll, beforeAll, expect, test } from "bun:test";
import { NetworkIoInTransactionError, withTenant } from "@offload/db";
import { auditActions, connect, connectionState, credentialRow, readCall, setup, type Env } from "./harness.ts";

let env: Env;
beforeAll(async () => {
  env = await setup();
});
afterAll(async () => {
  await env.stop();
});

const RUN = "00000000-0000-7000-8000-0000000000bb";
const refreshCalls = () => env.oauth.tokenCalls.filter((c) => c.form["grant_type"] === "refresh_token");

/** A connection with an oauth credential whose access token expired a minute ago. */
async function expired(): Promise<string> {
  const conn = await connect(env, env.fx.a, { provider: "google_sheets" });
  await env.broker.vault.put(
    env.fx.a.tenantId, conn, { kind: "oauth", access_token: "old-access-token", refresh_token: env.oauth.refreshToken },
    { scopes: ["s1"], expiresAt: new Date(env.clock.now().getTime() - 60_000) },
  );
  await env.fx.admin.query("update connections set state = 'active' where tenant_id = $1 and id = $2", [env.fx.a.tenantId, conn]);
  return conn;
}

test("REFRESH: two concurrent refreshes make one provider call", async () => {
  const conn = await expired();
  env.oauth.delayMs = 150;
  const before = refreshCalls().length;
  try {
    const [a, b] = await Promise.all([
      env.broker.refresh(env.fx.a.tenantId, conn),
      env.broker.refresh(env.fx.a.tenantId, conn),
    ]);
    expect([a, b].every((x) => x === "refreshed" || x === "fresh")).toBe(true);
  } finally {
    env.oauth.delayMs = 0;
  }
  expect(refreshCalls().length - before).toBe(1);
  expect(refreshCalls().at(-1)!.form).toMatchObject({ grant_type: "refresh_token", refresh_token: env.oauth.refreshToken, client_id: "test-client-id" });
  const row = await credentialRow(env, env.fx.a, conn);
  expect(row.refresh_state).toBe("ok");
  expect(row.refresh_lease_until).toBeNull();
  expect(row.last_refreshed_at).not.toBeNull();
  const fresh = (await env.broker.vault.get(env.fx.a.tenantId, conn)).secret;
  expect(fresh).toMatchObject({ kind: "oauth", refresh_token: env.oauth.refreshToken });
  expect((fresh as { access_token: string }).access_token).not.toBe("old-access-token");
  expect((await auditActions(env, env.fx.a)).filter((x) => x.action === "credential.refreshed" && x.details.connection_id === conn).length).toBe(1);
});

test("REFRESH: an expired lease lets the next caller refresh", async () => {
  const conn = await expired();
  const leaseUntil = new Date(env.clock.now().getTime() + 30_000);
  await env.fx.admin.query(
    "update credentials set refresh_state = 'refreshing', refresh_lease_until = $3 where tenant_id = $1 and connection_id = $2",
    [env.fx.a.tenantId, conn, leaseUntil],
  );
  const before = refreshCalls().length;
  env.clock.advance(10_000);
  await expect(env.broker.refresh(env.fx.a.tenantId, conn)).rejects.toMatchObject({ code: "state_conflict" });
  expect(refreshCalls().length).toBe(before); // the live lease is respected
  env.clock.advance(21_000); // 31 s after the lease was taken
  expect(await env.broker.refresh(env.fx.a.tenantId, conn)).toBe("refreshed");
  expect(refreshCalls().length).toBe(before + 1);
  expect((await credentialRow(env, env.fx.a, conn)).refresh_state).toBe("ok");
});

test("REFRESH: the refresh call runs outside any transaction", async () => {
  // Control: the fetch guard installed by the tenant fixture rejects network I/O inside withTenant.
  const inside = await withTenant(env.fx.app, env.fx.ctx(env.fx.a, env.fx.a.owner), () => fetch(env.oauth.userinfoUrl)).then(() => null, (e: unknown) => e);
  expect(inside).toBeInstanceOf(NetworkIoInTransactionError);
  // The same fetch from the refresh path succeeds, so it never runs inside a transaction.
  const conn = await expired();
  const before = refreshCalls().length;
  expect(await env.broker.refresh(env.fx.a.tenantId, conn)).toBe("refreshed");
  expect(refreshCalls().length).toBe(before + 1);
  // A call with an expired access token refreshes once and sends the new token upstream.
  const conn2 = await expired();
  env.scope.runs.set(RUN, ["thing.read"]);
  const r = await env.call("/call", readCall(env, env.fx.a, conn2, "thing.read", { run_id: RUN }));
  expect(r.status).toBe(200);
  expect(refreshCalls().length).toBe(before + 2);
  expect(env.upstream.requests.at(-1)!.headers["authorization"]).toBe(`Bearer ${env.oauth.accessToken(env.oauth.tokenCalls.length)}`);
});

test("REFRESH: a refused refresh marks the credential failed and the connection needs_reauth", async () => {
  const conn = await expired();
  env.oauth.refuseRefresh = true;
  try {
    await expect(env.broker.refresh(env.fx.a.tenantId, conn)).rejects.toMatchObject({ code: "state_conflict" });
  } finally {
    env.oauth.refuseRefresh = false;
  }
  const row = await credentialRow(env, env.fx.a, conn);
  expect(row.refresh_state).toBe("failed");
  expect(row.refresh_lease_until).toBeNull();
  expect(await connectionState(env, env.fx.a, conn)).toBe("needs_reauth");
  const before = env.upstream.requests.length;
  env.scope.runs.set(RUN, ["thing.read"]);
  const r = await env.call("/call", readCall(env, env.fx.a, conn, "thing.read", { run_id: RUN }));
  expect(r.status).toBe(409);
  expect(env.upstream.requests.length).toBe(before);
});
