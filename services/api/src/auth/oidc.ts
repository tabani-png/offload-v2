import { createLocalJWKSet, jwtVerify, type JSONWebKeySet } from "jose";
import type { Clock } from "../clock.ts";
import { systemClock } from "../clock.ts";

/**
 * One OIDC provider (ADR 0014): authorization code flow with PKCE S256 and a nonce, client_secret_post at the token
 * endpoint, ID token verified against the provider's JWKS. M1 uses Google through the owner's own Workspace OAuth
 * client (operator item O5); any standard provider works. Network calls happen here, never inside a transaction.
 */

export interface OidcIdentity {
  /** The provider's `sub`. */
  subject: string;
  email: string;
}

export interface OidcClient {
  /** The provider's issuer, part of the identity subject stored on members. */
  readonly issuer: string;
  authorizationUrl(p: { state: string; nonce: string; codeChallenge: string }): Promise<string>;
  /** Exchanges the code; throws OidcError when the provider or the ID token says no. */
  exchange(p: { code: string; codeVerifier: string; nonce: string }): Promise<OidcIdentity>;
}

export class OidcError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "OidcError";
  }
}

interface Discovery {
  issuer: string;
  authorization_endpoint: string;
  token_endpoint: string;
  jwks_uri: string;
}

export function createOidcClient(opts: {
  issuer: string;
  clientId: string;
  clientSecret: string;
  /** `${OFFLOAD_PUBLIC_BASE_URL}/auth/callback`. */
  redirectUri: string;
  fetch?: typeof fetch;
  clock?: Clock;
}): OidcClient {
  const http = opts.fetch ?? globalThis.fetch;
  const clock = opts.clock ?? systemClock;
  const issuer = opts.issuer.replace(/\/+$/, "");
  let discovery: Promise<Discovery> | null = null;

  const getJson = async (url: string, init?: RequestInit): Promise<any> => {
    const res = await http(url, { ...init, redirect: "error" });
    if (!res.ok) throw new OidcError(`provider answered ${res.status}`);
    return res.json();
  };
  const discover = () =>
    (discovery ??= (async () => {
      const d = (await getJson(`${issuer}/.well-known/openid-configuration`)) as Discovery;
      if (d.issuer !== issuer) throw new OidcError("discovery issuer does not match the configured issuer");
      for (const k of ["authorization_endpoint", "token_endpoint", "jwks_uri"] as const) {
        if (typeof d[k] !== "string" || !d[k].startsWith("https://")) throw new OidcError(`discovery ${k} must be https`);
      }
      return d;
    })().catch((err) => {
      discovery = null; // retry discovery on the next login
      throw err;
    }));

  return {
    issuer,
    async authorizationUrl(p) {
      const d = await discover();
      const u = new URL(d.authorization_endpoint);
      u.search = new URLSearchParams({
        response_type: "code", client_id: opts.clientId, redirect_uri: opts.redirectUri, scope: "openid email",
        state: p.state, nonce: p.nonce, code_challenge: p.codeChallenge, code_challenge_method: "S256",
      }).toString();
      return u.toString();
    },
    async exchange(p) {
      const d = await discover();
      const body = new URLSearchParams({
        grant_type: "authorization_code", code: p.code, redirect_uri: opts.redirectUri, code_verifier: p.codeVerifier,
        client_id: opts.clientId, client_secret: opts.clientSecret,
      });
      const tok = await getJson(d.token_endpoint, {
        method: "POST", headers: { "content-type": "application/x-www-form-urlencoded", accept: "application/json" }, body,
      });
      if (typeof tok?.id_token !== "string") throw new OidcError("no id_token");
      const jwks = createLocalJWKSet((await getJson(d.jwks_uri)) as JSONWebKeySet);
      let payload;
      try {
        ({ payload } = await jwtVerify(tok.id_token, jwks, {
          issuer, audience: opts.clientId, algorithms: ["RS256", "ES256"], currentDate: clock.now(), requiredClaims: ["sub", "exp", "iat"],
        }));
      } catch {
        throw new OidcError("id_token did not verify");
      }
      if (payload["nonce"] !== p.nonce) throw new OidcError("id_token nonce mismatch");
      const email = payload["email"];
      if (typeof email !== "string" || !email.includes("@")) throw new OidcError("id_token has no email");
      if (payload["email_verified"] !== true && payload["email_verified"] !== "true") throw new OidcError("email not verified");
      return { subject: payload.sub!, email };
    },
  };
}
