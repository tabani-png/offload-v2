import { expect, test } from "bun:test";
import type { TodoRuntime } from "../src/index.ts";

test("smoke: @offload/runtime loads and exports only its TODO marker", async () => {
  const mod = await import("../src/index.ts");
  // A type-only module has no runtime exports.
  expect(Object.keys(mod)).toEqual([]);
  const marker: TodoRuntime = "TODO: not implemented. See docs/ARCHITECTURE.md#11-routine-runtime";
  expect(marker.startsWith("TODO")).toBe(true);
});
