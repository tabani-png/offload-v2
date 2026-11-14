import type { ModelProvider, ModelRequest, ModelResponse } from "../types.ts";

/**
 * Messages API backend (ADR 0021, PR #42 A§9.2 owned loop): tool-less, structured output through
 * `output_config.format` when a schema is given, adaptive thinking, no `tool_choice`. `stop_reason` is read before
 * content: a refusal or any non-final stop returns no content.
 *
 * Raw fetch, not the SDK: the slice adds no dependency, and fetch is allowed only under providers/
 * (SECURITY_PRIVACY section 9). The key comes from `keySource`, read once by the composition root; it is never logged
 * or put in an error message.
 */

export const ANTHROPIC_VERSION = "2023-06-01";
/** Conservative estimator: fewer characters per token than typical, so reservations over-count. */
export const ESTIMATE_CHARS_PER_TOKEN = 3;

export class ProviderHttpError extends Error {
  constructor(readonly status: number) {
    super(`model provider returned HTTP ${status}`);
    this.name = "ProviderHttpError";
  }
}

export function estimateTokens(req: ModelRequest): number {
  let chars = req.system.length;
  for (const m of req.messages) chars += m.content.length + 8;
  if (req.schema !== undefined) chars += JSON.stringify(req.schema).length;
  return Math.ceil(chars / ESTIMATE_CHARS_PER_TOKEN) + 16;
}

interface MessagesResponse {
  stop_reason?: unknown;
  content?: Array<{ type?: unknown; text?: unknown }>;
  usage?: { input_tokens?: unknown; output_tokens?: unknown; cache_read_input_tokens?: unknown };
}

const num = (v: unknown): number => (typeof v === "number" && Number.isFinite(v) && v >= 0 ? v : 0);

export function anthropicMessages(baseUrl: string, keySource: () => string): ModelProvider {
  const key = keySource();
  const endpoint = new URL("/v1/messages", baseUrl).toString();
  return {
    estimateInputTokens: estimateTokens,
    async send(req: ModelRequest): Promise<ModelResponse> {
      const body: Record<string, unknown> = {
        model: req.model,
        max_tokens: req.max_tokens,
        system: req.system,
        messages: req.messages.map((m) => ({ role: m.role, content: m.content })),
        thinking: { type: "adaptive" },
      };
      if (req.schema !== undefined) body["output_config"] = { format: { type: "json_schema", schema: req.schema } };
      const res = await fetch(endpoint, {
        method: "POST",
        headers: { "content-type": "application/json", "x-api-key": key, "anthropic-version": ANTHROPIC_VERSION },
        body: JSON.stringify(body),
      });
      if (!res.ok) throw new ProviderHttpError(res.status);
      const msg = (await res.json()) as MessagesResponse;
      const stop_reason = typeof msg.stop_reason === "string" ? msg.stop_reason : "unknown";
      const usage = {
        input_tokens: num(msg.usage?.input_tokens),
        output_tokens: num(msg.usage?.output_tokens),
        cache_read_tokens: num(msg.usage?.cache_read_input_tokens),
      };
      // stop_reason first: only a finished turn carries usable content.
      if (stop_reason !== "end_turn" && stop_reason !== "stop_sequence") return { content: "", stop_reason, usage };
      const content = (msg.content ?? [])
        .filter((b) => b.type === "text" && typeof b.text === "string")
        .map((b) => b.text as string)
        .join("");
      return { content, stop_reason, usage };
    },
  };
}
