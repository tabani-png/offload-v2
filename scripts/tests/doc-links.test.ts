import { expect, test } from "bun:test";
import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { slug } from "../check-doc-links.ts";

const script = join(import.meta.dir, "..", "check-doc-links.ts");

test("slug follows GitHub heading rules", () => {
  expect(slug("8. Build orchestrator")).toBe("8-build-orchestrator");
  expect(slug("`OK, build` approval")).toBe("ok-build-approval");
});

test("fails on a missing target, passes on a good one", () => {
  const root = mkdtempSync(join(tmpdir(), "dl-"));
  writeFileSync(join(root, "a.md"), "# Title\n\n[ok](b.md#hello) [bad](missing.md)\n");
  writeFileSync(join(root, "b.md"), "## Hello\n");
  const bad = Bun.spawnSync(["bun", script, root], { stdout: "pipe", stderr: "pipe" });
  expect(bad.exitCode).toBe(1);
  writeFileSync(join(root, "a.md"), "# Title\n\n[ok](b.md#hello)\n");
  const good = Bun.spawnSync(["bun", script, root], { stdout: "pipe", stderr: "pipe" });
  expect(good.exitCode).toBe(0);
});
