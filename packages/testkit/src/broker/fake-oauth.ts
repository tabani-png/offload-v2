/**
 * FakeOAuthServer (m2-03): authorize, token and userinfo endpoints on 127.0.0.1, standing in for Google. Records every
 * token request (the form fields it received) so a test can check the client secret and PKCE verifier reached it.
 */

export interface TokenCall {
  form: Record<string, string>;
}

export interface FakeOAuthServer {
  host: string;
  authorizeUrl: string;
  tokenUrl: string;
  userinfoUrl: string;
  tokenCalls: TokenCall[];
  userinfoCalls: number;
  /** Delay before the token endpoint answers, in ms (for single-flight tests). */
  delayMs: number;
  /** When true the token endpoint refuses refresh_token grants with invalid_grant (HTTP 400). */
  refuseRefresh: boolean;
  /** Tokens it hands out; `n` counts calls so each access token differs. */
  accessToken(n: number): string;
  refreshToken: string;
  expiresIn: number;
  scope: string;
  account: { sub: string; email: string };
  stop(): Promise<void>;
}

export function fakeOAuthServer(): FakeOAuthServer {
  const tokenCalls: TokenCall[] = [];
  const s = {
    delayMs: 0,
    refuseRefresh: false,
    refreshToken: "fake-refresh-token-0001",
    expiresIn: 3600,
    scope: "https://www.googleapis.com/auth/spreadsheets",
    account: { sub: "1100223344", email: "owner@example.test" },
    userinfoCalls: 0,
    accessToken: (n: number) => `fake-access-token-${n}`,
  };
  const server = Bun.serve({
    hostname: "127.0.0.1",
    port: 0,
    async fetch(req) {
      const u = new URL(req.url);
      if (u.pathname === "/token" && req.method === "POST") {
        const form = Object.fromEntries(new URLSearchParams(await req.text()).entries());
        tokenCalls.push({ form });
        if (s.delayMs > 0) await new Promise((r) => setTimeout(r, s.delayMs));
        if (form["grant_type"] === "refresh_token" && s.refuseRefresh) {
          return Response.json({ error: "invalid_grant", error_description: "Token has been expired or revoked." }, { status: 400 });
        }
        const body: Record<string, unknown> = {
          access_token: s.accessToken(tokenCalls.length),
          expires_in: s.expiresIn,
          token_type: "Bearer",
          scope: s.scope,
        };
        if (form["grant_type"] === "authorization_code") body["refresh_token"] = s.refreshToken;
        return Response.json(body);
      }
      if (u.pathname === "/userinfo") {
        s.userinfoCalls++;
        if (!req.headers.get("authorization")?.startsWith("Bearer fake-access-token-")) return new Response("no", { status: 401 });
        return Response.json(s.account);
      }
      return new Response("not found", { status: 404 });
    },
  });
  const host = `127.0.0.1:${server.port}`;
  const self = {
    host,
    authorizeUrl: `http://${host}/authorize`,
    tokenUrl: `http://${host}/token`,
    userinfoUrl: `http://${host}/userinfo`,
    tokenCalls,
    stop: async () => {
      await server.stop(true);
    },
  };
  return Object.defineProperties(self, {
    userinfoCalls: { get: () => s.userinfoCalls, enumerable: true },
    delayMs: { get: () => s.delayMs, set: (v: number) => void (s.delayMs = v), enumerable: true },
    refuseRefresh: { get: () => s.refuseRefresh, set: (v: boolean) => void (s.refuseRefresh = v), enumerable: true },
    accessToken: { value: s.accessToken, enumerable: true },
    refreshToken: { get: () => s.refreshToken, enumerable: true },
    expiresIn: { get: () => s.expiresIn, set: (v: number) => void (s.expiresIn = v), enumerable: true },
    scope: { get: () => s.scope, enumerable: true },
    account: { get: () => s.account, enumerable: true },
  }) as unknown as FakeOAuthServer;
}
