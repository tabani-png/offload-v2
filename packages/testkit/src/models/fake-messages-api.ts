/**
 * fakeMessagesApi (m5-03): a Bun.serve on 127.0.0.1 that answers POST /v1/messages with canned Messages API responses
 * and records request bodies and the header names it received. Used to test the router's HTTP backend without calling
 * the Anthropic API. Header values are not recorded, except `anthropic-version`, so a key never lands in test output.
 */

export interface CannedMessage {
  stop_reason: string;
  content: Array<{ type: string; text?: string; thinking?: string }>;
  usage?: { input_tokens?: number; output_tokens?: number; cache_read_input_tokens?: number };
  status?: number;
}

export interface RecordedMessagesRequest {
  path: string;
  method: string;
  header_names: string[];
  anthropic_version: string | null;
  /** True when an x-api-key header was present and equal to `expectKey` (if given). */
  key_matched: boolean;
  body: Record<string, unknown>;
}

export interface FakeMessagesApi {
  url: string;
  requests: RecordedMessagesRequest[];
  stop(): void;
}

export function fakeMessagesApi(opts: { responses: CannedMessage[]; expectKey?: string }): FakeMessagesApi {
  const queue = [...opts.responses];
  const requests: RecordedMessagesRequest[] = [];
  const server = Bun.serve({
    hostname: "127.0.0.1",
    port: 0,
    async fetch(req) {
      const url = new URL(req.url);
      const body = (await req.json().catch(() => ({}))) as Record<string, unknown>;
      const key = req.headers.get("x-api-key");
      requests.push({
        path: url.pathname,
        method: req.method,
        header_names: [...req.headers.keys()].map((h) => h.toLowerCase()).sort(),
        anthropic_version: req.headers.get("anthropic-version"),
        key_matched: key !== null && (opts.expectKey === undefined || key === opts.expectKey),
        body,
      });
      const next = queue.shift();
      if (!next) return Response.json({ type: "error", error: { type: "api_error", message: "no canned response" } }, { status: 500 });
      const { status, ...msg } = next;
      return Response.json(
        {
          id: `msg_fake_${requests.length}`,
          type: "message",
          role: "assistant",
          model: typeof body["model"] === "string" ? body["model"] : "unknown",
          stop_details: null,
          ...msg,
          usage: { input_tokens: 0, output_tokens: 0, cache_read_input_tokens: 0, ...msg.usage },
        },
        { status: status ?? 200 },
      );
    },
  });
  return { url: `http://127.0.0.1:${server.port}`, requests, stop: () => server.stop(true) };
}
