import { expect, test } from "bun:test";
import type { TodoPolicy } from "../src/index.ts";

test("smoke: @offload/policy loads and exports only its TODO marker", async () => {
  const mod = await import("../src/index.ts");
  // A type-only module has no runtime exports.
  expect(Object.keys(mod)).toEqual([]);
  const marker: TodoPolicy = "TODO: not implemented. See docs/adr/0017-policy-engine-cedar.md";
  expect(marker.startsWith("TODO")).toBe(true);
});
