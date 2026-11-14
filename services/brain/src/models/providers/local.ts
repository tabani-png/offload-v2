import { parseLocalModelUrl } from "../local.ts";
import type { ModelProvider, ModelRequest, ModelResponse } from "../types.ts";
import { estimateTokens, ProviderHttpError } from "./anthropic.ts";

/**
 * Local tier backend (ADR 0021): an OpenAI-compatible chat completions endpoint (Ollama or exo) on loopback or a
 * private network. The host is checked again here. finish_reason is mapped to Messages API stop reasons
 * (`length` → `max_tokens`, `content_filter` → `refusal`) and read before content.
 */
export function localOpenAICompatible(url: string, model: string): ModelProvider {
  const endpoint = new URL("v1/chat/completions", parseLocalModelUrl(url).toString().replace(/\/?$/, "/")).toString();
  return {
    estimateInputTokens: estimateTokens,
    async send(req: ModelRequest): Promise<ModelResponse> {
      const body: Record<string, unknown> = {
        model,
        max_tokens: req.max_tokens,
        messages: [{ role: "system", content: req.system }, ...req.messages.map((m) => ({ role: m.role, content: m.content }))],
      };
      if (req.schema !== undefined) body["response_format"] = { type: "json_schema", json_schema: { name: "output", schema: req.schema } };
      const res = await fetch(endpoint, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(body) });
      if (!res.ok) throw new ProviderHttpError(res.status);
      const msg = (await res.json()) as {
        choices?: Array<{ finish_reason?: unknown; message?: { content?: unknown } }>;
        usage?: { prompt_tokens?: unknown; completion_tokens?: unknown };
      };
      const choice = msg.choices?.[0];
      const fr = choice?.finish_reason;
      const stop_reason = fr === "stop" ? "end_turn" : fr === "length" ? "max_tokens" : fr === "content_filter" ? "refusal" : "unknown";
      const n = (v: unknown) => (typeof v === "number" && Number.isFinite(v) && v >= 0 ? v : 0);
      const usage = { input_tokens: n(msg.usage?.prompt_tokens), output_tokens: n(msg.usage?.completion_tokens), cache_read_tokens: 0 };
      if (stop_reason !== "end_turn") return { content: "", stop_reason, usage };
      const content = typeof choice?.message?.content === "string" ? choice.message.content : "";
      return { content, stop_reason, usage };
    },
  };
}

/** One provider per tier: paid tiers go to `paid`, the local tier to `local`. */
export function byTier(providers: { paid: ModelProvider; local?: ModelProvider }): ModelProvider {
  const pick = (req: ModelRequest): ModelProvider => {
    if (req.tier !== "local") return providers.paid;
    if (!providers.local) throw new Error("local tier requested but no local provider is configured");
    return providers.local;
  };
  return {
    estimateInputTokens: (req) => pick(req).estimateInputTokens(req),
    send: async (req) => pick(req).send(req),
  };
}
