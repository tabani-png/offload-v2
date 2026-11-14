import { expect, test } from "bun:test";
import type { TodoBrain } from "../src/index.ts";

test("smoke: @offload/brain loads and exports only its TODO marker", async () => {
  const mod = await import("../src/index.ts");
  // A type-only module has no runtime exports.
  expect(Object.keys(mod)).toEqual([]);
  const marker: TodoBrain = "TODO: not implemented. See docs/ARCHITECTURE.md#5-cloud-brain-and-user-model";
  expect(marker.startsWith("TODO")).toBe(true);
});
