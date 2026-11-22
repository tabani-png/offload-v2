import { expect, test } from "bun:test";
import { cosine, EMBED_DIMS, localEmbedder } from "../../src/understanding/embed.ts";

test("EMBED: the local embedder is deterministic, 1024 dims and unit norm", async () => {
  const e = localEmbedder();
  expect(e.id).toBe("local:hash:1024");
  expect(e.dims).toBe(EMBED_DIMS);
  expect(EMBED_DIMS).toBe(1024);
  const [a, b] = await e.embed(["create bill ledgerly supplier amount", "create bill ledgerly supplier amount"]);
  expect(a).toHaveLength(1024);
  expect(a).toEqual(b!);
  expect(Math.abs(Math.hypot(...a!) - 1)).toBeLessThan(1e-9);
  const [again] = await localEmbedder().embed(["create bill ledgerly supplier amount"]);
  expect(again).toEqual(a!);
});

test("EMBED: alike descriptions are close and unrelated ones are far", async () => {
  const [a, b, c] = await localEmbedder().embed([
    "ledgerly create bill supplier reference amount due date",
    "ledgerly create bill supplier amount save approve",
    "pasta recipe tomato basil garlic simmer",
  ]);
  expect(cosine(a!, b!)).toBeGreaterThan(0.7);
  expect(cosine(a!, c!)).toBeLessThan(0.3);
  expect(cosine(a!, a!)).toBeCloseTo(1, 9);
});
