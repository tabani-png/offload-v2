import { expect, test } from "bun:test";
import type { TodoConnectorsSdk } from "../src/index.ts";

test("smoke: @offload/connectors-sdk loads and exports only its TODO marker", async () => {
  const mod = await import("../src/index.ts");
  // A type-only module has no runtime exports.
  expect(Object.keys(mod)).toEqual([]);
  const marker: TodoConnectorsSdk = "TODO: not implemented. See docs/adr/0010-mcp-first-connectors.md";
  expect(marker.startsWith("TODO")).toBe(true);
});
