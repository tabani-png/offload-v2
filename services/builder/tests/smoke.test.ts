import { expect, test } from "bun:test";
import type { TodoBuilder } from "../src/index.ts";

test("smoke: @offload/builder loads and exports only its TODO marker", async () => {
  const mod = await import("../src/index.ts");
  // A type-only module has no runtime exports.
  expect(Object.keys(mod)).toEqual([]);
  const marker: TodoBuilder = "TODO: not implemented. See docs/ARCHITECTURE.md#8-build-orchestrator";
  expect(marker.startsWith("TODO")).toBe(true);
});
