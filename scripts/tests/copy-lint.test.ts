import { afterAll, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const script = join(import.meta.dir, "..", "check-copy.sh");
const dirs: string[] = [];
afterAll(() => dirs.forEach((d) => rmSync(d, { recursive: true, force: true })));

function fixture(files: Record<string, string>): string {
  const root = mkdtempSync(join(tmpdir(), "copy-"));
  dirs.push(root);
  const all = { "README.md": "# Offload\n\nPlain tagline.\n", ...files };
  for (const [path, body] of Object.entries(all)) {
    const full = join(root, path);
    mkdirSync(join(full, ".."), { recursive: true });
    writeFileSync(full, body);
  }
  return root;
}

function run(root: string): number {
  return Bun.spawnSync(["bash", script, root], { stdout: "pipe", stderr: "pipe" }).exitCode;
}

test("COPY: passes clean product strings", () => {
  const root = fixture({
    "apps/mac/Sources/OffloadMac/Today.swift": 'let title = "One fix for today"\n',
    "packages/contracts/src/copy/today.ts": 'export const title = "One fix for today";\n',
  });
  expect(run(root)).toBe(0);
});

test("COPY: a Keychain identifier containing Unlock is not copy", () => {
  const root = fixture({
    "apps/mac/Sources/OffloadStore/KeyVault.swift":
      "let access = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly // keys unlock after first login\n",
  });
  expect(run(root)).toBe(0);
});

test("COPY: a banned word inside a Swift string literal fails", () => {
  const root = fixture({ "apps/mac/Sources/OffloadMac/Today.swift": 'let t = "Unlock your day"\n' });
  expect(run(root)).toBe(1);
});

test("COPY: banned words match whole words only", () => {
  const root = fixture({ "apps/web/src/x.tsx": 'export const t = "Robustness tests ran";\n' });
  expect(run(root)).toBe(0);
});

test("COPY: a banned phrase in a copy module fails", () => {
  const root = fixture({ "packages/contracts/src/copy/plans.ts": "export const t = 'Built for teams that ship';\n" });
  expect(run(root)).toBe(1);
});

test("COPY: a banned word in a .strings file fails", () => {
  const root = fixture({ "apps/mac/Resources/en.lproj/Localizable.strings": '"cta" = "A seamless start";\n' });
  expect(run(root)).toBe(1);
});

test("COPY: an em dash in a product string fails", () => {
  const root = fixture({ "apps/mac/Sources/OffloadMac/Today.swift": 'let t = "Saved 2 hours — nice"\n' });
  expect(run(root)).toBe(1);
});

test("COPY: an em dash in a code comment is not copy", () => {
  const root = fixture({ "apps/web/src/x.ts": "// a note — for engineers\nexport const t = \"ok\";\n" });
  expect(run(root)).toBe(0);
});

test("COPY: an em dash in the README tagline fails", () => {
  const root = fixture({ "README.md": "# Offload\n\nAdmin work — done.\n" });
  expect(run(root)).toBe(1);
});

test("DRYRUN: a dryRun identifier in a service fails", () => {
  const root = fixture({ "services/api/src/routes.ts": "export const dryRun = false;\n" });
  expect(run(root)).toBe(1);
});

test("DRYRUN: a dry_run field in contracts fails", () => {
  const root = fixture({ "packages/contracts/src/build.ts": "export type B = { dry_run: boolean };\n" });
  expect(run(root)).toBe(1);
});

test("DRYRUN: preview run in ee code fails", () => {
  const root = fixture({ "ee/packages/governance/src/x.ts": "// start a preview run first\n" });
  expect(run(root)).toBe(1);
});

test("DRYRUN: dry-run in a Swift source fails", () => {
  const root = fixture({ "apps/mac/Sources/OffloadMac/x.swift": "// dry-run mode\n" });
  expect(run(root)).toBe(1);
});
