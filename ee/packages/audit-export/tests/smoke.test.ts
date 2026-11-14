import { expect, test } from "bun:test";
import type { TodoEeAuditExport } from "../src/index.ts";

test("smoke: @offload-ee/audit-export loads and exports only its TODO marker", async () => {
  const mod = await import("../src/index.ts");
  // A type-only module has no runtime exports.
  expect(Object.keys(mod)).toEqual([]);
  const marker: TodoEeAuditExport = "TODO: not implemented. See docs/OPEN_CORE.md";
  expect(marker.startsWith("TODO")).toBe(true);
});
