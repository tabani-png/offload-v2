import { expect, test } from "bun:test";
import type { TodoContracts } from "../src/index.ts";

test("smoke: @offload/contracts loads and exports only its TODO marker", async () => {
  const mod = await import("../src/index.ts");
  // A type-only module has no runtime exports.
  expect(Object.keys(mod)).toEqual([]);
  const marker: TodoContracts = "TODO: not implemented. See docs/ARCHITECTURE.md#4-contracts";
  expect(marker.startsWith("TODO")).toBe(true);
});
