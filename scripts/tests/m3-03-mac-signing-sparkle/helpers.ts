// Shared fixtures for the m3-03 bun suite: fixture app bundles, a fake codesign, script runner, plist and workflow
// readers. Everything runs on Linux; nothing here calls Apple tools or the network.
import { chmodSync, mkdirSync, mkdtempSync, readFileSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";

export const ROOT = join(import.meta.dir, "..", "..", "..");
export const PKG = join(ROOT, "apps/mac/Packaging");
export const WORKFLOWS = join(ROOT, ".github/workflows");

/** The six release secret names (DEPLOYMENT section 13). */
export const SECRET_NAMES = [
  "DEVELOPER_ID_P12_BASE64",
  "DEVELOPER_ID_P12_PASSWORD",
  "ASC_KEY_ID",
  "ASC_ISSUER_ID",
  "ASC_KEY_P8",
  "SPARKLE_ED_PRIVATE_KEY",
] as const;

/** Mach-O 64-bit little-endian magic (cf fa ed fe) plus padding. */
export const MACHO = Buffer.concat([Buffer.from([0xcf, 0xfa, 0xed, 0xfe]), Buffer.alloc(60, 1)]);

const dirs: string[] = [];
export function tmp(prefix = "m303-"): string {
  const d = mkdtempSync(join(tmpdir(), prefix));
  dirs.push(d);
  return d;
}
export function cleanup(): void {
  for (const d of dirs.splice(0)) rmSync(d, { recursive: true, force: true });
}

function put(path: string, body: string | Buffer, mode = 0o644): void {
  mkdirSync(dirname(path), { recursive: true });
  writeFileSync(path, body);
  chmodSync(path, mode);
}

/** A fake `codesign` that logs its arguments and rejects any file containing the word UNSIGNED. */
export function fakeCodesign(dir: string): { bin: string; log: string } {
  const bin = join(dir, "fakebin", "codesign");
  const log = join(dir, "codesign.log");
  put(
    bin,
    [
      "#!/bin/bash",
      `printf '%s\\n' "$*" >> "${log}"`,
      'last="${!#}"',
      'if [ -f "$last" ] && grep -q UNSIGNED "$last"; then echo "$last: code object is not signed at all" >&2; exit 1; fi',
      "exit 0",
      "",
    ].join("\n"),
    0o755,
  );
  return { bin, log };
}

/** What `swift build -c release` leaves behind that bundle.sh needs: the executable and Sparkle.framework. */
export function fakeBuildDir(dir: string): string {
  const b = join(dir, "build");
  put(join(b, "Offload"), MACHO, 0o755);
  addSparkleFramework(join(b, "Sparkle.framework"));
  return b;
}

/** Sparkle 2's framework layout: versioned, with Autoupdate, Updater.app and two XPC services. */
export function addSparkleFramework(fw: string): void {
  const v = join(fw, "Versions/B");
  put(join(v, "Sparkle"), MACHO, 0o755);
  put(join(v, "Autoupdate"), MACHO, 0o755);
  put(join(v, "Updater.app/Contents/MacOS/Updater"), MACHO, 0o755);
  put(join(v, "Updater.app/Contents/Info.plist"), "<plist/>");
  put(join(v, "XPCServices/Installer.xpc/Contents/MacOS/Installer"), MACHO, 0o755);
  put(join(v, "XPCServices/Downloader.xpc/Contents/MacOS/Downloader"), MACHO, 0o755);
  put(join(v, "Resources/Info.plist"), "<plist/>");
  symlinkSync("B", join(fw, "Versions/Current"));
  symlinkSync("Versions/Current/Sparkle", join(fw, "Sparkle"));
  symlinkSync("Versions/Current/Resources", join(fw, "Resources"));
  symlinkSync("Versions/Current/XPCServices", join(fw, "XPCServices"));
}

/** A complete, valid fixture bundle (as bundle.sh would produce it). */
export function fixtureApp(dir: string): string {
  const app = join(dir, "Offload.app");
  const c = join(app, "Contents");
  put(join(c, "Info.plist"), '<?xml version="1.0"?>\n<plist version="1.0"><dict></dict></plist>\n');
  put(join(c, "MacOS/Offload"), MACHO, 0o755);
  addSparkleFramework(join(c, "Frameworks/Sparkle.framework"));
  put(join(c, "Resources/THIRD_PARTY_NOTICES.txt"), "notices\n");
  return app;
}

export type Result = { code: number; out: string; err: string; all: string };

/** Runs a packaging script with exactly `env` (no inherited environment) plus a minimal PATH. */
export function runScript(script: string, args: string[], env: Record<string, string> = {}): Result {
  const p = Bun.spawnSync(["/bin/bash", join(PKG, script), ...args], {
    env: { PATH: "/usr/bin:/bin:/usr/sbin:/sbin", ...env },
    stdout: "pipe",
    stderr: "pipe",
  });
  const out = p.stdout.toString();
  const err = p.stderr.toString();
  return { code: p.exitCode ?? -1, out, err, all: out + err };
}

/** Runs a packaging script under `env -i` (the environment is empty, not even PATH). */
export function runEmptyEnv(script: string, args: string[]): Result {
  const p = Bun.spawnSync(["/usr/bin/env", "-i", "/bin/bash", join(PKG, script), ...args], {
    stdout: "pipe",
    stderr: "pipe",
  });
  const out = p.stdout.toString();
  const err = p.stderr.toString();
  return { code: p.exitCode ?? -1, out, err, all: out + err };
}

export function readPackaging(name: string): string {
  return readFileSync(join(PKG, name), "utf8");
}

/** plutil-free reader for the flat key/value dict of an XML Info.plist. */
export function parsePlist(xml: string): Record<string, string | boolean | number> {
  const out: Record<string, string | boolean | number> = {};
  const re = /<key>([^<]*)<\/key>\s*(?:<string>([^<]*)<\/string>|<(true|false)\/>|<integer>(-?\d+)<\/integer>)/g;
  for (let m = re.exec(xml); m; m = re.exec(xml)) {
    const key = m[1]!;
    if (m[2] !== undefined) out[key] = m[2];
    else if (m[3] !== undefined) out[key] = m[3] === "true";
    else out[key] = Number(m[4]);
  }
  return out;
}

export function readWorkflow(name: string): { text: string; doc: any } {
  const text = readFileSync(join(WORKFLOWS, name), "utf8");
  return { text, doc: Bun.YAML.parse(text) };
}

/** The `on:` block; YAML 1.1 parsers turn the key `on` into `true`. */
export function triggers(doc: any): Record<string, any> {
  const on = doc.on ?? doc[true as unknown as string] ?? {};
  if (typeof on === "string") return { [on]: null };
  if (Array.isArray(on)) return Object.fromEntries(on.map((k) => [k, null]));
  return on;
}
