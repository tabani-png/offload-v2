import { expect, test } from "bun:test";
import type { TodoLicense } from "../src/index.ts";

test("smoke: @offload/license loads and exports only its TODO marker", async () => {
  const mod = await import("../src/index.ts");
  // A type-only module has no runtime exports.
  expect(Object.keys(mod)).toEqual([]);
  const marker: TodoLicense = "TODO: not implemented. See docs/adr/0015-open-core-layout-and-license-gating.md";
  expect(marker.startsWith("TODO")).toBe(true);
});
