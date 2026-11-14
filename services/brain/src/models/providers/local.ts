import type { ModelProvider } from "../types.ts";

export function localOpenAICompatible(_url: string, _model: string): ModelProvider {
  throw new Error("not implemented");
}
