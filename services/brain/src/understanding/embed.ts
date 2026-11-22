// Local embeddings (EMBED): deterministic feature hashing (old brain/src/understanding/embed.ts StubEmbedder idea,
// written fresh). Stemmed words weigh 1, word bigrams 0.5, into signed buckets; unit norm. No model, no network:
// the default embedder for every deploy until a local model endpoint serves `embed` (ARCHITECTURE section 17).
import { createHash } from "node:crypto";

export interface Embedder {
  /** For example `local:hash:1024`. */
  readonly id: string;
  readonly dims: number;
  /** One vector per text, same order. */
  embed(texts: readonly string[]): Promise<number[][]>;
}

export const EMBED_DIMS = 1024;

export function cosine(a: readonly number[], b: readonly number[]): number {
  const n = Math.min(a.length, b.length);
  let dot = 0;
  let na = 0;
  let nb = 0;
  for (let i = 0; i < n; i++) {
    dot += a[i]! * b[i]!;
    na += a[i]! * a[i]!;
    nb += b[i]! * b[i]!;
  }
  return na === 0 || nb === 0 ? 0 : dot / Math.sqrt(na * nb);
}

/** Crude stem so "invoices" and "invoice", "reading" and "read" share a feature. */
function stem(w: string): string {
  if (w.length > 5 && w.endsWith("ing")) return w.slice(0, -3);
  if (w.length > 4 && w.endsWith("es")) return w.slice(0, -2);
  if (w.length > 3 && w.endsWith("s") && !w.endsWith("ss")) return w.slice(0, -1);
  return w;
}

function bucket(feature: string, dims: number): { i: number; sign: number } {
  const h = createHash("sha256").update(feature).digest();
  return { i: h.readUInt32BE(0) % dims, sign: (h[4]! & 1) === 0 ? 1 : -1 };
}

export function embedText(text: string, dims: number = EMBED_DIMS): number[] {
  const v = new Array<number>(dims).fill(0);
  const words = text.toLowerCase().split(/[^\p{L}]+/u).filter((w) => w.length >= 2).map(stem);
  const add = (f: string, w: number) => {
    const b = bucket(f, dims);
    v[b.i]! += b.sign * w;
  };
  for (const w of words) add(`w:${w}`, 1);
  for (let i = 1; i < words.length; i++) add(`b:${words[i - 1]} ${words[i]}`, 0.5);
  const norm = Math.sqrt(v.reduce((s, x) => s + x * x, 0));
  return norm === 0 ? v : v.map((x) => x / norm);
}

export function localEmbedder(dims: number = EMBED_DIMS): Embedder {
  return { id: `local:hash:${dims}`, dims, embed: async (texts) => texts.map((t) => embedText(t, dims)) };
}
