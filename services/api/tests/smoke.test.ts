import { expect, test } from "bun:test";
import type { TodoApi } from "../src/index.ts";

test("smoke: @offload/api loads and exports only its TODO marker", async () => {
  const mod = await import("../src/index.ts");
  // A type-only module has no runtime exports.
  expect(Object.keys(mod)).toEqual([]);
  const marker: TodoApi = "TODO: not implemented. See docs/ARCHITECTURE.md#3-ingest";
  expect(marker.startsWith("TODO")).toBe(true);
});
