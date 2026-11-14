// Shared fixtures for the m3-09 test build suite. Runs apps/mac/TestBuild/build-app.sh on Linux with fake macOS
// tools (codesign, ditto) on PATH. No network, no real signing.
import { chmodSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

export const repo = join(import.meta.dir, "..", "..", "..");
export const script = join(repo, "apps/mac/TestBuild/build-app.sh");
export const guide = join(repo, "apps/mac/TestBuild/INSTALL_AND_TEST.md");
export const workflow = join(repo, ".github/workflows/mac-artifact.yml");

const dirs: string[] = [];
export function tmp(prefix = "m309-"): string {
  const d = mkdtempSync(join(tmpdir(), prefix));
  dirs.push(d);
  return d;
}
export function cleanup() {
  for (const d of dirs.splice(0)) rmSync(d, { recursive: true, force: true });
}

export function exe(path: string, body: string) {
  writeFileSync(path, body);
  chmodSync(path, 0o755);
}

/** A bin folder with a fake codesign (logs its arguments, marks signed bundles) and a fake ditto (cp -R). */
export function fakeTools(): { bin: string; log: string } {
  const bin = join(tmp("m309-bin-"), "bin");
  mkdirSync(bin, { recursive: true });
  const log = join(bin, "..", "codesign.log");
  exe(
    join(bin, "codesign"),
    `#!/bin/sh
echo "$*" >> "${log}"
for last; do :; done
case " $* " in
  *" --sign "*) mkdir -p "$last/Contents/_CodeSignature" && echo adhoc > "$last/Contents/_CodeSignature/CodeResources"; exit 0 ;;
  *" --verify "*) [ -f "$last/Contents/_CodeSignature/CodeResources" ] && exit 0; echo "$last: code object is not signed at all" >&2; exit 1 ;;
  *" -dv"*) if [ -f "$last/Contents/_CodeSignature/CodeResources" ]; then echo "Executable=$last/Contents/MacOS/Offload" >&2; echo "Signature=adhoc" >&2; exit 0; fi; echo "$last: code object is not signed at all" >&2; exit 1 ;;
esac
exit 0
`,
  );
  exe(
    join(bin, "ditto"),
    `#!/bin/sh
[ "$1" = "-c" ] && { echo "fake ditto: archive mode not supported" >&2; exit 1; }
cp -R "$1" "$2"
`,
  );
  return { bin, log };
}

export type Run = { code: number; out: string; err: string };
export function run(args: string[], env: Record<string, string> = {}, bin?: string): Run {
  const PATH = (bin ? bin + ":" : "") + (process.env["PATH"] ?? "/usr/bin:/bin");
  const p = Bun.spawnSync(["bash", script, ...args], {
    env: { PATH, HOME: process.env["HOME"] ?? "/tmp", ...env },
    stdout: "pipe",
    stderr: "pipe",
  });
  return { code: p.exitCode ?? -1, out: p.stdout.toString(), err: p.stderr.toString() };
}

/** Reads <key>K</key><string|true|false .../> pairs from a flat plist dict. */
export type PlistKey =
  | "CFBundleIdentifier" | "CFBundleExecutable" | "CFBundleName" | "CFBundleDisplayName" | "CFBundlePackageType"
  | "CFBundleShortVersionString" | "CFBundleVersion" | "OffloadCommit" | "OffloadBuildKind" | "LSMinimumSystemVersion"
  | "LSUIElement" | "LSApplicationCategoryType" | "NSPrincipalClass" | "NSHighResolutionCapable"
  | "NSScreenCaptureUsageDescription";
export function plistValues(xml: string): Partial<Record<PlistKey, string | boolean>> {
  const out: Record<string, string | boolean> = {};
  const re = /<key>([^<]+)<\/key>\s*(?:<string>([^<]*)<\/string>|<(true|false)\/>)/g;
  let m: RegExpExecArray | null;
  while ((m = re.exec(xml))) out[m[1] ?? ""] = m[3] ? m[3] === "true" : unescape(m[2] ?? "");
  return out;
}
function unescape(s: string) {
  return s.replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/&quot;/g, '"').replace(/&apos;/g, "'").replace(/&amp;/g, "&");
}

/** A fake release binary: a shell script that answers --version and writes its environment to envFile. */
export function fakeBinary(dir: string, line: string, envFile: string, code = 0): string {
  const p = join(dir, "Offload");
  exe(p, `#!/bin/sh\nenv > "${envFile}"\necho "SELF=$0" >> "${envFile}"\n[ "$1" = "--version" ] && echo "${line}"\nexit ${code}\n`);
  return p;
}
