import { expect, test } from "bun:test";
import type { TodoTestkit } from "../src/index.ts";

test("smoke: @offload/testkit loads and exports only its TODO marker", async () => {
  const mod = await import("../src/index.ts");
  // A type-only module has no runtime exports.
  expect(Object.keys(mod)).toEqual([]);
  const marker: TodoTestkit = "TODO: not implemented. See AGENTS.md";
  expect(marker.startsWith("TODO")).toBe(true);
});
