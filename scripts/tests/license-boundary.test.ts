import { afterAll, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const script = join(import.meta.dir, "..", "check-license-boundary.sh");
const dirs: string[] = [];
afterAll(() => dirs.forEach((d) => rmSync(d, { recursive: true, force: true })));

function fixture(files: Record<string, string>): string {
  const root = mkdtempSync(join(tmpdir(), "lb-"));
  dirs.push(root);
  for (const [path, body] of Object.entries(files)) {
    const full = join(root, path);
    mkdirSync(join(full, ".."), { recursive: true });
    writeFileSync(full, body);
  }
  return root;
}

function run(root: string): number {
  return Bun.spawnSync(["bash", script, root], { stdout: "pipe", stderr: "pipe" }).exitCode;
}

test("passes when core does not import ee", () => {
  const root = fixture({
    "packages/a/src/index.ts": 'import { x } from "@offload/b";\n',
    "ee/packages/z/src/index.ts": 'import { a } from "@offload/a";\n',
  });
  expect(run(root)).toBe(0);
});

test("fails on a static import of @offload-ee from core", () => {
  const root = fixture({ "services/api/src/index.ts": 'import { sso } from "@offload-ee/identity";\n' });
  expect(run(root)).toBe(1);
});

test("fails on a relative path into ee/", () => {
  const root = fixture({ "packages/a/src/x.ts": 'export * from "../../../ee/packages/governance/src/index.ts";\n' });
  expect(run(root)).toBe(1);
});

test("fails on a dynamic import of ee", () => {
  const root = fixture({ "apps/web/src/x.ts": 'const m = await import("@offload-ee/audit-export");\n' });
  expect(run(root)).toBe(1);
});

test("fails when a core manifest depends on an ee package", () => {
  const root = fixture({
    "packages/a/src/index.ts": "export {};\n",
    "packages/a/package.json": '{ "dependencies": { "@offload-ee/identity": "workspace:*" } }\n',
  });
  expect(run(root)).toBe(1);
});
