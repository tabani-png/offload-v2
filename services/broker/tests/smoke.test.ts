import { expect, test } from "bun:test";
import type { TodoBroker } from "../src/index.ts";

test("smoke: @offload/broker loads and exports only its TODO marker", async () => {
  const mod = await import("../src/index.ts");
  // A type-only module has no runtime exports.
  expect(Object.keys(mod)).toEqual([]);
  const marker: TodoBroker = "TODO: not implemented. See docs/adr/0034-credential-broker-and-key-providers.md";
  expect(marker.startsWith("TODO")).toBe(true);
});
