import { createHash, generateKeyPairSync, randomBytes, webcrypto } from "node:crypto";
import { SignJWT, exportJWK, generateKeyPair, type JWK } from "jose";

/**
 * Auth fakes for m1-04 and later slices: a fake clock, a fake OIDC issuer (discovery, JWKS, token endpoint) served by
 * an in-process `fetch` (no sockets, no real provider), a fake mailer, device keys that sign the way the Mac does
 * (P-256, raw r‖s, base64url) and a device-token signing key. Nothing here touches the network.
 */

export function base64url(bytes: Uint8Array): string {
  return Buffer.from(bytes).toString("base64url");
}

/** A clock tests move by hand. Services take `{ now(): Date }`. */
export class FakeClock {
  #t: number;
  constructor(start: Date | string = "2026-11-14T09:00:00.000Z") {
    this.#t = new Date(start).getTime();
  }
  now(): Date {
    return new Date(this.#t);
  }
  advance(ms: number): void {
    this.#t += ms;
  }
  advanceMinutes(min: number): void {
    this.advance(min * 60_000);
  }
}

/** PKCE S256 pair (RFC 7636): verifier of 43 unreserved characters and its challenge. */
export function pkcePair(): { verifier: string; challenge: string } {
  const verifier = base64url(randomBytes(32));
  const challenge = createHash("sha256").update(verifier).digest("base64url");
  return { verifier, challenge };
}

export interface FakeOidcUser {
  subject: string;
  email: string;
  emailVerified?: boolean;
}

export interface FakeOidcIssuer {
  issuer: string;
  clientId: string;
  clientSecret: string;
  /** Serves discovery, JWKS and the token endpoint; anything else throws (tests never reach a real host). */
  fetch: typeof fetch;
  /**
   * Plays the browser and the user at the provider: checks the authorization URL the API redirected to, records a
   * code and returns the callback URL (redirect_uri with code and state).
   */
  authorize(authorizationUrl: string, user: FakeOidcUser): string;
  /** Number of token requests served (tests assert the exchange happened outside transactions etc.). */
  tokenRequests(): number;
}

interface PendingCode {
  user: FakeOidcUser;
  nonce: string;
  challenge: string;
  redirectUri: string;
}

export async function fakeOidcIssuer(opts: {
  issuer?: string;
  clientId?: string;
  clientSecret?: string;
  now?: () => Date;
} = {}): Promise<FakeOidcIssuer> {
  const issuer = opts.issuer ?? "https://idp.example.test";
  const clientId = opts.clientId ?? "offload-test-client";
  const clientSecret = opts.clientSecret ?? base64url(randomBytes(24));
  const now = opts.now ?? (() => new Date());
  const { privateKey, publicKey } = await generateKeyPair("ES256", { extractable: true });
  const jwk: JWK = { ...(await exportJWK(publicKey)), kid: "fake-1", alg: "ES256", use: "sig" };
  const codes = new Map<string, PendingCode>();
  let served = 0;

  const json = (body: unknown, status = 200) =>
    new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });

  const handler = async (input: string | URL | Request, init?: RequestInit): Promise<Response> => {
    const req = input instanceof Request ? input : new Request(input, init);
    const url = new URL(req.url);
    if (url.origin !== new URL(issuer).origin) throw new Error("fake OIDC issuer: request to a host it does not serve");
    if (req.method === "GET" && url.pathname === "/.well-known/openid-configuration") {
      return json({
        issuer, authorization_endpoint: `${issuer}/authorize`, token_endpoint: `${issuer}/token`, jwks_uri: `${issuer}/jwks`,
        response_types_supported: ["code"], id_token_signing_alg_values_supported: ["ES256"],
        code_challenge_methods_supported: ["S256"], token_endpoint_auth_methods_supported: ["client_secret_post"],
      });
    }
    if (req.method === "GET" && url.pathname === "/jwks") return json({ keys: [jwk] });
    if (req.method === "POST" && url.pathname === "/token") {
      served++;
      const form = new URLSearchParams(await req.text());
      if (form.get("grant_type") !== "authorization_code") return json({ error: "unsupported_grant_type" }, 400);
      if (form.get("client_id") !== clientId || form.get("client_secret") !== clientSecret) return json({ error: "invalid_client" }, 401);
      const code = form.get("code") ?? "";
      const pending = codes.get(code);
      codes.delete(code);
      if (!pending) return json({ error: "invalid_grant" }, 400);
      if (form.get("redirect_uri") !== pending.redirectUri) return json({ error: "invalid_grant" }, 400);
      const verifier = form.get("code_verifier") ?? "";
      if (createHash("sha256").update(verifier).digest("base64url") !== pending.challenge) return json({ error: "invalid_grant" }, 400);
      const iat = Math.floor(now().getTime() / 1000);
      const idToken = await new SignJWT({ email: pending.user.email, email_verified: pending.user.emailVerified ?? true, nonce: pending.nonce })
        .setProtectedHeader({ alg: "ES256", kid: "fake-1" })
        .setIssuer(issuer).setAudience(clientId).setSubject(pending.user.subject)
        .setIssuedAt(iat).setExpirationTime(iat + 300)
        .sign(privateKey);
      return json({ access_token: base64url(randomBytes(16)), token_type: "Bearer", expires_in: 300, id_token: idToken });
    }
    return json({ error: "not_found" }, 404);
  };

  return {
    issuer, clientId, clientSecret,
    fetch: handler as typeof fetch,
    tokenRequests: () => served,
    authorize(authorizationUrl, user) {
      const u = new URL(authorizationUrl);
      if (`${u.origin}${u.pathname}` !== `${issuer}/authorize`) throw new Error("fake OIDC issuer: not its authorization endpoint");
      const p = u.searchParams;
      if (p.get("response_type") !== "code") throw new Error("fake OIDC issuer: response_type must be code");
      if (p.get("client_id") !== clientId) throw new Error("fake OIDC issuer: unknown client_id");
      if (p.get("code_challenge_method") !== "S256") throw new Error("fake OIDC issuer: PKCE S256 required");
      if (!(p.get("scope") ?? "").split(" ").includes("openid")) throw new Error("fake OIDC issuer: scope openid required");
      const redirectUri = p.get("redirect_uri") ?? "";
      const code = base64url(randomBytes(16));
      codes.set(code, { user, nonce: p.get("nonce") ?? "", challenge: p.get("code_challenge") ?? "", redirectUri });
      const cb = new URL(redirectUri);
      cb.searchParams.set("code", code);
      cb.searchParams.set("state", p.get("state") ?? "");
      return cb.toString();
    },
  };
}

/** Captures magic links instead of sending mail. */
export class FakeMailer {
  readonly sent: { to: string; url: string }[] = [];
  async sendMagicLink(to: string, url: string): Promise<void> {
    this.sent.push({ to, url });
  }
  last(): { to: string; url: string } {
    const m = this.sent.at(-1);
    if (!m) throw new Error("FakeMailer: nothing sent");
    return m;
  }
}

export interface DeviceKey {
  /** Public part only: { kty: "EC", crv: "P-256", x, y }. */
  publicJwk: JsonWebKey;
  /** ECDSA P-256 / SHA-256 over the bytes; 64-byte raw r‖s (Swift rawRepresentation), base64url, no padding. */
  sign(data: Uint8Array | string): Promise<string>;
  /** The same signature DER-encoded (Swift derRepresentation): the server must refuse it. */
  signDer(data: Uint8Array | string): Promise<string>;
}

const bytesOf = (d: Uint8Array | string) => (typeof d === "string" ? new TextEncoder().encode(d) : d);

/** A device key the way the Mac makes one (P-256). */
export async function deviceKey(): Promise<DeviceKey> {
  const pair = await webcrypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"]);
  const full = await webcrypto.subtle.exportKey("jwk", pair.publicKey);
  const publicJwk: JsonWebKey = { kty: "EC", crv: "P-256", x: full.x!, y: full.y! };
  const raw = async (d: Uint8Array | string) =>
    new Uint8Array(await webcrypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, pair.privateKey, bytesOf(d)));
  return {
    publicJwk,
    sign: async (d) => base64url(await raw(d)),
    signDer: async (d) => base64url(rawToDer(await raw(d))),
  };
}

/** IEEE P1363 r‖s (64 bytes) to an ASN.1 DER ECDSA-Sig-Value. */
export function rawToDer(raw: Uint8Array): Uint8Array {
  if (raw.length !== 64) throw new Error("rawToDer: need 64 bytes");
  const int = (b: Uint8Array) => {
    let i = 0;
    while (i < b.length - 1 && b[i] === 0) i++;
    let v = b.slice(i);
    if (v[0]! & 0x80) v = Uint8Array.from([0, ...v]);
    return Uint8Array.from([0x02, v.length, ...v]);
  };
  const r = int(raw.slice(0, 32));
  const s = int(raw.slice(32));
  return Uint8Array.from([0x30, r.length + s.length, ...r, ...s]);
}

/** An ES256 (P-256) device-token signing key: PKCS#8 PEM for the API, public JWK for tests that verify tokens. */
export function deviceTokenSigningKey(): { pkcs8Pem: string; publicJwk: JsonWebKey } {
  const { privateKey, publicKey } = generateKeyPairSync("ec", { namedCurve: "prime256v1" });
  return {
    pkcs8Pem: privateKey.export({ type: "pkcs8", format: "pem" }).toString(),
    publicJwk: publicKey.export({ format: "jwk" }) as JsonWebKey,
  };
}
