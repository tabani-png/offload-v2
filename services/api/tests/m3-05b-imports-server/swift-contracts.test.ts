import { expect, test } from "bun:test";
import { mkdtempSync, readFileSync, readdirSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";

/**
 * The import contracts reach the Mac as generated Swift (m3-02's gen-swift.ts). The Swift test "UPLOAD: generated
 * Swift types are fresh" only runs on macOS, so these two checks catch a stale or clashing generation on Linux too.
 */

const repo = resolve(import.meta.dir, "../../../..");
const committedDir = join(repo, "apps/mac/Sources/OffloadContracts/Generated");
const swiftFiles = (dir: string) => readdirSync(dir).filter((f) => f.endsWith(".swift")).sort();

function generate(): { dir: string; files: string[] } {
  const dir = mkdtempSync(join(tmpdir(), "offload-gen-swift-"));
  const run = Bun.spawnSync(["bun", join(repo, "packages/contracts/scripts/gen-swift.ts"), "--out", dir], { cwd: repo });
  expect(run.exitCode).toBe(0);
  return { dir, files: swiftFiles(dir) };
}

/** Top-level public type names declared in the Swift files of `dir`. */
function publicTypes(dir: string): Set<string> {
  const names = new Set<string>();
  for (const f of swiftFiles(dir)) {
    const text = readFileSync(join(dir, f), "utf8");
    for (const m of text.matchAll(/^public (?:final )?(?:struct|enum|class|actor|protocol|typealias) ([A-Za-z_][A-Za-z0-9_]*)/gm)) names.add(m[1]!);
  }
  return names;
}

test("IMPORT: the committed generated Swift types match gen-swift.ts, import types included", () => {
  const { dir, files } = generate();
  try {
    expect(files).toEqual(swiftFiles(committedDir));
    for (const f of files) expect(`${f}\n${readFileSync(join(committedDir, f), "utf8")}`).toBe(`${f}\n${readFileSync(join(dir, f), "utf8")}`);
    expect(files).toEqual(expect.arrayContaining(["OpenImportRequest.swift", "Import.swift", "ForgetRequest.swift", "PurgeRequestState.swift"]));
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("IMPORT: generated Swift types do not reuse a public type name OffloadImport declares", () => {
  // OffloadImport does not import OffloadContracts, so a file importing both could not name a shared type without a
  // module prefix (the Mac app's import composition names `ImportSourceKind` unqualified).
  const { dir } = generate();
  try {
    const generated = publicTypes(dir);
    const importer = publicTypes(join(repo, "apps/mac/Sources/OffloadImport"));
    expect(importer.has("ImportSourceKind")).toBe(true);
    expect([...generated].filter((n) => importer.has(n))).toEqual([]);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});
