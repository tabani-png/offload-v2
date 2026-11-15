/**
 * fakeUpstream(): a Bun.serve on 127.0.0.1 that records the headers and body of every request it receives (m2-03).
 * `respond` shapes the reply; by default it answers 200 `{"ok":true}`.
 */

export interface UpstreamRequest {
  method: string;
  path: string;
  headers: Record<string, string>;
  body: string;
}

export interface FakeUpstream {
  /** `127.0.0.1:port`: what a provider host allowlist entry looks like for this server. */
  host: string;
  url: string;
  requests: UpstreamRequest[];
  respond: (req: UpstreamRequest) => Response | Promise<Response>;
  stop(): Promise<void>;
}

export function fakeUpstream(): FakeUpstream {
  const requests: UpstreamRequest[] = [];
  const state = {
    respond: (_req: UpstreamRequest): Response | Promise<Response> => Response.json({ ok: true }),
  };
  const server = Bun.serve({
    hostname: "127.0.0.1",
    port: 0,
    async fetch(req) {
      const u = new URL(req.url);
      const headers: Record<string, string> = {};
      req.headers.forEach((v, k) => {
        headers[k.toLowerCase()] = v;
      });
      const rec: UpstreamRequest = { method: req.method, path: u.pathname + u.search, headers, body: await req.text() };
      requests.push(rec);
      return state.respond(rec);
    },
  });
  const host = `127.0.0.1:${server.port}`;
  return {
    host,
    url: `http://${host}`,
    requests,
    get respond() {
      return state.respond;
    },
    set respond(fn) {
      state.respond = fn;
    },
    stop: async () => {
      await server.stop(true);
    },
  };
}
