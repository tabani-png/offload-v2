import { FakeClock, FakeMailer, deviceTokenSigningKey, fakeOidcIssuer, pgTenantFixture } from "@offload/testkit";
import { fakeSigner } from "@offload/testkit/src/audit/index.ts";
import { createApp, createOidcClient } from "../../src/index.ts";
import { BASE, session, user, type Harness } from "../m1-04-login-devices/harness.ts";

export { BASE, session, user };

/** m1-04's harness plus the audit signer, so GET /v1/audit-events/verify can check anchor signatures. */
export interface AuditHarness extends Harness {
  signer: ReturnType<typeof fakeSigner>;
}

export async function makeHarness(): Promise<AuditHarness> {
  const fx = await pgTenantFixture();
  const clock = new FakeClock("2026-11-14T09:00:00.000Z");
  const issuer = await fakeOidcIssuer({ now: () => clock.now() });
  const mailer = new FakeMailer();
  const signingKey = deviceTokenSigningKey();
  const signer = fakeSigner();
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
    signer,
  });
  return {
    fx, clock, issuer, mailer, signingKey, signer,
    req: async (path, init = {}) => {
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
