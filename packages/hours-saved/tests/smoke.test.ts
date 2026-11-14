import { expect, test } from "bun:test";
import type { TodoHoursSaved } from "../src/index.ts";

test("smoke: @offload/hours-saved loads and exports only its TODO marker", async () => {
  const mod = await import("../src/index.ts");
  // A type-only module has no runtime exports.
  expect(Object.keys(mod)).toEqual([]);
  const marker: TodoHoursSaved = "TODO: not implemented. See docs/adr/0003-numbers-come-from-code.md";
  expect(marker.startsWith("TODO")).toBe(true);
});
