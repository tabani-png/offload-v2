import { expect, test } from "bun:test";
import type { TodoMasking } from "../src/index.ts";

test("smoke: @offload/masking loads and exports only its TODO marker", async () => {
  const mod = await import("../src/index.ts");
  // A type-only module has no runtime exports.
  expect(Object.keys(mod)).toEqual([]);
  const marker: TodoMasking = "TODO: not implemented. See docs/adr/0005-masked-text-only-reaches-models.md";
  expect(marker.startsWith("TODO")).toBe(true);
});
