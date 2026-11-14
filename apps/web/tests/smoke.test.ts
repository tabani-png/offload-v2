import { expect, test } from "bun:test";
import type { TodoWeb } from "../src/index.ts";

test("smoke: @offload/web loads and exports only its TODO marker", async () => {
  const mod = await import("../src/index.ts");
  // A type-only module has no runtime exports.
  expect(Object.keys(mod)).toEqual([]);
  const marker: TodoWeb = "TODO: not implemented. See docs/PRODUCT.md";
  expect(marker.startsWith("TODO")).toBe(true);
});
