/**
 * FakeModelProvider (m5-03): scripted replies per tier for the model router. It records every request it receives so
 * tests can assert what would have reached a model. Never calls a network. Structurally matches the router's
 * `ModelProvider` port (services/brain/src/models/types.ts); testkit does not import the brain.
 */

export type FakeTier = "opus" | "sonnet" | "haiku" | "local";

/** A scripted reply: a named outcome or an exact response. */
export type FakeReply =
  | "ok"
  | "refusal"
  | "cut_off"
  | "invalid_json"
  | "error"
  | {
      content: string;
      stop_reason?: string;
      usage?: { input_tokens?: number; output_tokens?: number; cache_read_tokens?: number };
    };

export interface FakeModelRequest {
  call_id: string;
  attempt: number;
  tier: FakeTier;
  model: string;
  system: string;
  messages: Array<{ role: "user" | "assistant"; content: string }>;
  max_tokens: number;
  schema?: unknown;
}

export interface FakeModelResponse {
  content: string;
  stop_reason: string;
  usage: { input_tokens: number; output_tokens: number; cache_read_tokens: number };
}

export interface FakeModelProviderOptions {
  /** Replies consumed in order per tier; when a tier's list is empty, `fallback` is used. */
  script?: Partial<Record<FakeTier, FakeReply[]>>;
  /** Reply when nothing is scripted. Default "ok". */
  fallback?: FakeReply;
  /** Content of an "ok" reply. Default `{"label":"high"}`. */
  okContent?: string;
  /** Output tokens reported for a scripted outcome. Default 10. */
  outputTokens?: number;
}

/** Characters per token for the fake estimator. The fake counts 4; real adapters count more conservatively. */
export const FAKE_CHARS_PER_TOKEN = 4;

export class FakeModelProvider {
  readonly requests: FakeModelRequest[] = [];
  private readonly script: Partial<Record<FakeTier, FakeReply[]>>;
  private readonly fallback: FakeReply;
  private readonly okContent: string;
  private readonly outputTokens: number;

  constructor(opts: FakeModelProviderOptions = {}) {
    this.script = {};
    for (const [tier, replies] of Object.entries(opts.script ?? {})) {
      this.script[tier as FakeTier] = [...(replies ?? [])];
    }
    this.fallback = opts.fallback ?? "ok";
    this.okContent = opts.okContent ?? '{"label":"high"}';
    this.outputTokens = opts.outputTokens ?? 10;
  }

  estimateInputTokens(req: FakeModelRequest): number {
    let chars = req.system.length;
    for (const m of req.messages) chars += m.content.length;
    if (req.schema !== undefined) chars += JSON.stringify(req.schema).length;
    return Math.ceil(chars / FAKE_CHARS_PER_TOKEN);
  }

  async send(req: FakeModelRequest): Promise<FakeModelResponse> {
    this.requests.push(structuredClone(req));
    const queue = this.script[req.tier];
    const reply = queue && queue.length > 0 ? (queue.shift() as FakeReply) : this.fallback;
    const input_tokens = this.estimateInputTokens(req);
    if (typeof reply === "object") {
      return {
        content: reply.content,
        stop_reason: reply.stop_reason ?? "end_turn",
        usage: {
          input_tokens: reply.usage?.input_tokens ?? input_tokens,
          output_tokens: reply.usage?.output_tokens ?? this.outputTokens,
          cache_read_tokens: reply.usage?.cache_read_tokens ?? 0,
        },
      };
    }
    const usage = { input_tokens, output_tokens: this.outputTokens, cache_read_tokens: 0 };
    switch (reply) {
      case "ok":
        return { content: this.okContent, stop_reason: "end_turn", usage };
      case "refusal":
        return { content: "", stop_reason: "refusal", usage };
      case "cut_off":
        return { content: this.okContent.slice(0, 3), stop_reason: "max_tokens", usage: { ...usage, output_tokens: req.max_tokens } };
      case "invalid_json":
        return { content: "not json {", stop_reason: "end_turn", usage };
      case "error":
        throw new Error("fake provider error");
    }
  }

  /** Tiers of the recorded requests, in order. */
  tiers(): FakeTier[] {
    return this.requests.map((r) => r.tier);
  }
}
