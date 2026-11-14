import { expect, test } from "bun:test";
import type { TodoDb } from "../src/index.ts";

test("smoke: @offload/db loads and exports only its TODO marker", async () => {
  const mod = await import("../src/index.ts");
  // A type-only module has no runtime exports.
  expect(Object.keys(mod)).toEqual([]);
  const marker: TodoDb = "TODO: not implemented. See docs/DATA_MODEL.md";
  expect(marker.startsWith("TODO")).toBe(true);
});
