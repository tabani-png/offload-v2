// Local embeddings: deterministic feature hashing, 1024 dims.
export interface Embedder {
  readonly id: string;
  readonly dims: number;
  embed(texts: readonly string[]): Promise<number[][]>;
}

export const EMBED_DIMS = 1024;

export function localEmbedder(_dims: number = EMBED_DIMS): Embedder {
  throw new Error("not implemented");
}

export function cosine(_a: readonly number[], _b: readonly number[]): number {
  throw new Error("not implemented");
}
