import { expect, test } from "bun:test";
import type { TodoEeServer } from "../src/index.ts";

test("smoke: @offload-ee/server-ee loads and exports only its TODO marker", async () => {
  const mod = await import("../src/index.ts");
  // A type-only module has no runtime exports.
  expect(Object.keys(mod)).toEqual([]);
  const marker: TodoEeServer = "TODO: not implemented. See docs/OPEN_CORE.md";
  expect(marker.startsWith("TODO")).toBe(true);
});
