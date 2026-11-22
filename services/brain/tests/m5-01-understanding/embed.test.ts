import { expect, test } from "bun:test";
import { describeSpans } from "../../src/understanding/describe.ts";
import { cosine, EMBED_DIMS, localEmbedder } from "../../src/understanding/embed.ts";
import { sessionize } from "../../src/understanding/sessionize.ts";
import { invoiceImport } from "./fixtures.ts";

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
    // The same step on two instances: the words differ where one frame showed more of the form.
    "google chrome ledgerly create bill new supplier reference amount due date save approve",
    "google chrome ledgerly create bill new supplier amount due date save",
    "pasta recipe tomato basil garlic simmer",
  ]);
  expect(cosine(a!, b!)).toBeGreaterThan(0.7);
  expect(cosine(a!, c!)).toBeLessThan(0.3);
  expect(cosine(a!, a!)).toBeCloseTo(1, 9);
});

test("EMBED: one step on two generated instances is close; a noise clip on another surface is far", async () => {
  const fx = invoiceImport(["2026-11-10"], { perDay: 2, noise: true });
  const d = await describeSpans(sessionize(fx.observations, fx.texts), "UTC");
  const web = d.filter((x) => x.host === "app.ledgerly.example");
  const noise = d.find((x) => x.words.includes("roadmap"))!;
  expect(web).toHaveLength(2);
  const [a, b, c] = await localEmbedder().embed([web[0]!.text, web[1]!.text, noise.text]);
  expect(cosine(a!, b!)).toBeGreaterThan(0.7);
  expect(cosine(a!, c!)).toBeLessThan(0.3);
});
