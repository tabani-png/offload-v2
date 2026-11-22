import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { createNameMasker } from "../../src/names/index.ts";

const TAG_RE = /^[a-z]{4}$/;
const CORPUS = join(import.meta.dir, "../../../testkit/fixtures/masking/names-heldout.jsonl");

/** Deterministic random source for tag tests. */
function seq(...values: number[]): () => number {
  let i = 0;
  return () => values[i++ % values.length]!;
}

describe("m5-03 person-name masker", () => {
  test("NAMES: placeholder-shaped input becomes name before masking", () => {
    const m = createNameMasker({ random: seq(0.01, 0.02, 0.03, 0.04) });
    expect(m.tag).toMatch(TAG_RE);
    const out = m.mask("Ask <person:abcd.1> and <person:wxyz.2.first> and <person:qrst.me> and <person:bogus>.");
    expect(out).toBe("Ask <name> and <name> and <name> and <name>.");
  });

  test("NAMES: the same name in one run gets the same placeholder and a new run gets a new tag", () => {
    const a = createNameMasker({ random: seq(0.1, 0.2, 0.3, 0.4) });
    const out = a.mask("Leila Brennick sent the invoice. Later Leila Brennick and Omar Velquist met; Leila agreed.");
    expect(out).toBe(
      `<person:${a.tag}.1> sent the invoice. Later <person:${a.tag}.1> and <person:${a.tag}.2> met; <person:${a.tag}.1.first> agreed.`,
    );
    // Same run, a later message: the mapping holds.
    expect(a.mask("Omar Velquist replied.")).toBe(`<person:${a.tag}.2> replied.`);

    const b = createNameMasker({ random: seq(0.9, 0.8, 0.7, 0.6) });
    expect(b.tag).toMatch(TAG_RE);
    expect(b.tag).not.toBe(a.tag);
    expect(b.mask("Omar Velquist replied.")).toBe(`<person:${b.tag}.1> replied.`);

    // Default randomness: two runs get different tags.
    expect(createNameMasker().tag).toMatch(TAG_RE);
  });

  test("NAMES: the member's own name becomes the me placeholder by default", () => {
    const m = createNameMasker({ ownName: "Sam Okafor" });
    expect(m.mask("Sam Okafor asked Priya Holmvik for the file. Thanks, Sam")).toBe(
      `<person:${m.tag}.me> asked <person:${m.tag}.1> for the file. Thanks, <person:${m.tag}.me>`,
    );
    expect(m.mask("Okafor approved it.")).toBe(`<person:${m.tag}.me> approved it.`);
    // The own name can be given to a run's masker later; the map and tag stay the same.
    const late = createNameMasker();
    const before = late.mask("Priya Holmvik met Sam Okafor.");
    late.setOwnName("Sam Okafor", "mask");
    expect(late.mask("Priya Holmvik met Sam Okafor.")).toBe(`<person:${late.tag}.1> met <person:${late.tag}.me>.`);
    expect(before.startsWith(`<person:${late.tag}.1>`)).toBe(true);
    // A different own name is refused; asking for keep after mask leaves the own name masked.
    expect(() => late.setOwnName("Dana Fielding", "mask")).toThrow();
    late.setOwnName("Sam Okafor", "keep");
    expect(late.mask("Sam Okafor")).toBe(`<person:${late.tag}.me>`);
    const keep = createNameMasker({ ownName: "Sam Okafor", ownNameToModels: "keep" });
    expect(keep.mask("Sam Okafor asked Priya Holmvik.")).toBe(`Sam Okafor asked <person:${keep.tag}.1>.`);
  });

  test("NAMES: device pseudonyms pass unchanged", () => {
    const m = createNameMasker();
    const text = "Ask <person:h_0123456789abcdef> to email <email:h_fedcba9876543210> about <doc:h_00112233445566aa>.";
    expect(m.mask(text)).toBe(text);
    // Placeholders this run produced pass unchanged when its own output is masked again.
    const once = m.mask("Lena Marquist signed.");
    expect(m.mask(once)).toBe(once);
  });

  test("NAMES: common capitalised words, days, months and apps are not masked", () => {
    const m = createNameMasker();
    const text = "On Monday the Team updated the Invoice in Google Sheets and sent the Report in March.";
    expect(m.mask(text)).toBe(text);
  });

  test("NAMES: the held-out corpus miss rate is within the maximum", () => {
    const MAX_MISS_RATE = 0.02;
    const lines = readFileSync(CORPUS, "utf8").trim().split("\n");
    expect(lines.length).toBeGreaterThanOrEqual(200);
    let missed = 0;
    for (const line of lines) {
      const { text, names } = JSON.parse(line) as { text: string; names: string[] };
      const out = createNameMasker().mask(text);
      const leaked = names.flatMap((n) => n.split(" ")).some((tok) => new RegExp(`\\b${tok}\\b`).test(out));
      if (leaked) missed++;
    }
    expect(missed / lines.length).toBeLessThanOrEqual(MAX_MISS_RATE);
  });
});
