import { afterAll, expect, test } from "bun:test";
import { existsSync, lstatSync, mkdirSync, readFileSync, statSync, symlinkSync, writeFileSync } from "node:fs";
import { createHash } from "node:crypto";
import { join } from "node:path";
import { cleanup, fakeBinary, fakeTools, plistValues, repo, run, tmp } from "./helpers";

afterAll(cleanup);

const SHA = "0123456789abcdef0123456789abcdef01234567";
const BUNDLE_ID = "ai.offload.mac.dev";

// ---- PLIST ---------------------------------------------------------------

test("PLIST: the test build has the dev bundle id, the executable name, the stamped version and the commit", () => {
  const r = run(["info-plist", "1.2.3", "42", "abc1234"]);
  expect(r.code).toBe(0);
  const v = plistValues(r.out);
  expect(v.CFBundleIdentifier).toBe(BUNDLE_ID);
  expect(v.CFBundleExecutable).toBe("Offload");
  expect(v.CFBundleName).toBe("Offload");
  expect(v.CFBundleDisplayName).toBe("Offload");
  expect(v.CFBundlePackageType).toBe("APPL");
  expect(v.CFBundleShortVersionString).toBe("1.2.3");
  expect(v.CFBundleVersion).toBe("42");
  expect(v.OffloadCommit).toBe("abc1234");
  expect(v.OffloadBuildKind).toBe("test");
});

test("PLIST: macOS 14.0 minimum, menu bar app, productivity category and the screen reading usage string", () => {
  const v = plistValues(run(["info-plist", "0.1.0", "1", "abc1234"]).out);
  expect(v.LSMinimumSystemVersion).toBe("14.0");
  expect(v.LSUIElement).toBe(true);
  expect(v.LSApplicationCategoryType).toBe("public.app-category.productivity");
  expect(v.NSPrincipalClass).toBe("NSApplication");
  expect(v.NSHighResolutionCapable).toBe(true);
  expect(v.NSScreenCaptureUsageDescription).toBe("Offload reads what's on screen, on this Mac, to understand your work.");
});

test("PLIST: the output is a well-formed plist document with no Sparkle keys", () => {
  const out = run(["info-plist", "0.1.0", "1", "abc1234"]).out;
  expect(out.startsWith('<?xml version="1.0" encoding="UTF-8"?>')).toBe(true);
  expect(out).toContain("<!DOCTYPE plist");
  expect(out.trim().endsWith("</plist>")).toBe(true);
  expect((out.match(/<key>/g) ?? []).length).toBe((out.match(/<\/key>/g) ?? []).length);
  expect(out).not.toMatch(/SUFeedURL|SUPublicEDKey|SURequireSignedFeed/);
});

test("PLIST: a version that is not MAJOR.MINOR.PATCH, a non-numeric build or a non-hex commit exits 2", () => {
  expect(run(["info-plist", "1.2", "1", "abc1234"]).code).toBe(2);
  expect(run(["info-plist", "1.2.3-beta", "1", "abc1234"]).code).toBe(2);
  expect(run(["info-plist", "1.2.3", "x1", "abc1234"]).code).toBe(2);
  expect(run(["info-plist", "1.2.3", "1", "abc12"]).code).toBe(2);
  expect(run(["info-plist", "1.2.3", "1", "<script>"]).code).toBe(2);
  expect(run(["info-plist"]).code).toBe(2);
});

// ---- STAMP ---------------------------------------------------------------

test("STAMP: the VERSION file is MAJOR.MINOR.PATCH and the version command prints it", () => {
  const file = readFileSync(join(repo, "apps/mac/TestBuild/VERSION"), "utf8").trim();
  expect(file).toMatch(/^\d+\.\d+\.\d+$/);
  const r = run(["version"]);
  expect(r.code).toBe(0);
  expect(r.out.trim()).toBe(file);
});

test("STAMP: the zip is named Offload-mac-<first 7 characters of the commit>.zip", () => {
  const r = run(["artifact-name", SHA]);
  expect(r.code).toBe(0);
  expect(r.out.trim()).toBe("Offload-mac-0123456.zip");
  expect(run(["artifact-name", "ABCDEF0123"]).out.trim()).toBe("Offload-mac-abcdef0.zip");
});

test("STAMP: an artifact name for a value that is not a commit is refused", () => {
  expect(run(["artifact-name", "main"]).code).toBe(2);
  expect(run(["artifact-name", "../../x"]).code).toBe(2);
  expect(run(["artifact-name"]).code).toBe(2);
});

// ---- ASSEMBLE ------------------------------------------------------------

function assembled(env: Record<string, string> = {}) {
  const d = tmp();
  const bindir = join(d, "release");
  mkdirSync(bindir);
  const bin = fakeBinary(bindir, "x", join(d, "env.txt"));
  const out = join(d, "out");
  const r = run(["assemble", bin, out], env);
  return { d, bindir, out, app: join(out, "Offload.app"), r };
}

test("ASSEMBLE: the bundle has Info.plist, PkgInfo, an executable MacOS/Offload and Resources", () => {
  const { app, r } = assembled();
  expect(r.code).toBe(0);
  expect(existsSync(join(app, "Contents/Info.plist"))).toBe(true);
  expect(readFileSync(join(app, "Contents/PkgInfo"), "utf8")).toBe("APPL????");
  const exe = join(app, "Contents/MacOS/Offload");
  expect(statSync(exe).mode & 0o111).not.toBe(0);
  expect(statSync(join(app, "Contents/Resources")).isDirectory()).toBe(true);
});

test("ASSEMBLE: Info.plist is stamped from VERSION, OFFLOAD_BUILD_NUMBER and OFFLOAD_COMMIT", () => {
  const { app } = assembled({ OFFLOAD_BUILD_NUMBER: "77", OFFLOAD_COMMIT: SHA });
  const v = plistValues(readFileSync(join(app, "Contents/Info.plist"), "utf8"));
  const version = readFileSync(join(repo, "apps/mac/TestBuild/VERSION"), "utf8").trim();
  expect(v.CFBundleShortVersionString).toBe(version);
  expect(v.CFBundleVersion).toBe("77");
  expect(v.OffloadCommit).toBe("0123456");
  expect(v.CFBundleIdentifier).toBe(BUNDLE_ID);
});

test("ASSEMBLE: without build inputs the build number is 1 and the commit 0000000", () => {
  const { app } = assembled();
  const v = plistValues(readFileSync(join(app, "Contents/Info.plist"), "utf8"));
  expect(v.CFBundleVersion).toBe("1");
  expect(v.OffloadCommit).toBe("0000000");
});

test("ASSEMBLE: a SwiftPM resource bundle beside the binary stops the build, because Bundle.module would not find it", () => {
  // SwiftPM's generated Bundle.module looks at the .app root and the build machine's path, never Contents/Resources,
  // and codesign refuses files at the .app root, so an installed copy would crash on first use (review 1 finding 11).
  const d = tmp();
  const bindir = join(d, "release");
  mkdirSync(join(bindir, "OffloadMac_OffloadMac.bundle"), { recursive: true });
  writeFileSync(join(bindir, "OffloadMac_OffloadMac.bundle/a.json"), "{}");
  const bin = fakeBinary(bindir, "x", join(d, "env.txt"));
  const r = run(["assemble", bin, join(d, "out")]);
  expect(r.code).toBe(1);
  expect(r.err).toContain("OffloadMac_OffloadMac.bundle");
  expect(r.err).toContain("Bundle.module");
  expect(existsSync(join(d, "out", "Offload.app"))).toBe(false);
});

test("ASSEMBLE: the bundle carries the license and the third-party notices and no bun or brain", () => {
  const { app, r } = assembled();
  expect(r.code).toBe(0);
  expect(readFileSync(join(app, "Contents/Resources/LICENSE.txt"), "utf8")).toBe(readFileSync(join(repo, "LICENSE"), "utf8"));
  expect(readFileSync(join(app, "Contents/Resources/THIRD_PARTY_NOTICES.txt"), "utf8")).toBe(readFileSync(join(repo, "NOTICE"), "utf8"));
  expect(existsSync(join(app, "Contents/Helpers"))).toBe(false);
  expect(existsSync(join(app, "Contents/Resources/offload"))).toBe(false);
});

/** A stand-in for SwiftPM's Sparkle.framework beside the release binary (versioned layout with symlinks). */
function sparkleBeside(bindir: string): string {
  const fw = join(bindir, "Sparkle.framework");
  mkdirSync(join(fw, "Versions/B/Updater.app/Contents/MacOS"), { recursive: true });
  mkdirSync(join(fw, "Versions/B/XPCServices/Installer.xpc"), { recursive: true });
  writeFileSync(join(fw, "Versions/B/Sparkle"), "framework");
  writeFileSync(join(fw, "Versions/B/Autoupdate"), "autoupdate");
  symlinkSync("B", join(fw, "Versions/Current"));
  symlinkSync("Versions/Current/Sparkle", join(fw, "Sparkle"));
  return fw;
}

function assembledWithSparkle() {
  const d = tmp();
  const bindir = join(d, "release");
  mkdirSync(bindir);
  sparkleBeside(bindir);
  const bin = fakeBinary(bindir, "x", join(d, "env.txt"));
  const out = join(d, "out");
  const r = run(["assemble", bin, out]);
  const app = join(out, "Offload.app");
  return { app, fw: join(app, "Contents/Frameworks/Sparkle.framework"), r };
}

test("ASSEMBLE: Sparkle.framework beside the binary is copied into Contents/Frameworks with its symlinks", () => {
  // Since the rebase onto main, the Offload executable links Sparkle (m3-03) and loads it from
  // @executable_path/../Frameworks; without the framework the app would not launch.
  const { fw, r } = assembledWithSparkle();
  expect(r.code).toBe(0);
  expect(readFileSync(join(fw, "Versions/B/Sparkle"), "utf8")).toBe("framework");
  expect(lstatSync(join(fw, "Versions/Current")).isSymbolicLink()).toBe(true);
  expect(lstatSync(join(fw, "Sparkle")).isSymbolicLink()).toBe(true);
});

test("ASSEMBLE: without Sparkle.framework beside the binary the bundle has no Frameworks folder", () => {
  const { app, r } = assembled();
  expect(r.code).toBe(0);
  expect(existsSync(join(app, "Contents/Frameworks"))).toBe(false);
});

test("ASSEMBLE: a missing binary fails without creating a bundle", () => {
  const d = tmp();
  const r = run(["assemble", join(d, "nope"), join(d, "out")]);
  expect(r.code).not.toBe(0);
  expect(existsSync(join(d, "out", "Offload.app"))).toBe(false);
});

// ---- ADHOC ---------------------------------------------------------------

test("ADHOC: sign uses an ad hoc identity and never signs with --deep", () => {
  const { app } = assembled();
  const { bin, log } = fakeTools();
  expect(run(["sign", app], {}, bin).code).toBe(0);
  const calls = readFileSync(log, "utf8").trim().split("\n");
  const signs = calls.filter((c) => c.includes("--sign"));
  expect(signs.length).toBeGreaterThan(0);
  for (const c of signs) {
    expect(c).toMatch(/--sign - /);
    expect(c).not.toContain("--deep");
  }
});

test("ADHOC: with Sparkle.framework, sign drops its XPC services and signs Autoupdate, Updater.app, the framework, then the app", () => {
  const { app, fw } = assembledWithSparkle();
  const { bin, log } = fakeTools();
  expect(run(["sign", app], {}, bin).code).toBe(0);
  expect(existsSync(join(fw, "Versions/B/XPCServices"))).toBe(false);
  const signs = readFileSync(log, "utf8").trim().split("\n").filter((c) => c.includes("--sign"));
  expect(signs.map((c) => c.split(" ").pop())).toEqual([
    join(fw, "Versions/B/Autoupdate"),
    join(fw, "Versions/B/Updater.app"),
    fw,
    app,
  ]);
  for (const c of signs) {
    expect(c).toMatch(/--sign - /);
    expect(c).not.toContain("--deep");
    expect(c).not.toContain("runtime");
  }
});

test("ADHOC: check passes a signed bundle that carries Sparkle.framework", () => {
  const { app } = assembledWithSparkle();
  const { bin } = fakeTools();
  run(["sign", app], {}, bin);
  const r = run(["check", app], {}, bin);
  expect(r.err + r.out).not.toContain("FAIL");
  expect(r.code).toBe(0);
});

test("ADHOC: check passes an assembled, ad hoc signed bundle", () => {
  const { app } = assembled();
  const { bin } = fakeTools();
  run(["sign", app], {}, bin);
  const r = run(["check", app], {}, bin);
  expect(r.err + r.out).not.toContain("FAIL");
  expect(r.code).toBe(0);
});

test("ADHOC: check fails an unsigned bundle", () => {
  const { app } = assembled();
  const { bin } = fakeTools();
  const r = run(["check", app], {}, bin);
  expect(r.code).toBe(1);
  expect(r.out).toContain("FAIL");
});

test("ADHOC: check fails a bundle with the release bundle id or without the menu bar flag", () => {
  const { bin } = fakeTools();
  const a = assembled().app;
  const pa = join(a, "Contents/Info.plist");
  writeFileSync(pa, readFileSync(pa, "utf8").replace(BUNDLE_ID, "ai.offload.mac"));
  run(["sign", a], {}, bin);
  const ra = run(["check", a], {}, bin);
  expect(ra.code).toBe(1);
  expect(ra.out).toContain("CFBundleIdentifier");

  const b = assembled().app;
  const pb = join(b, "Contents/Info.plist");
  writeFileSync(pb, readFileSync(pb, "utf8").replace(/<key>LSUIElement<\/key>\s*<true\/>/, ""));
  run(["sign", b], {}, bin);
  const rb = run(["check", b], {}, bin);
  expect(rb.code).toBe(1);
  expect(rb.out).toContain("LSUIElement");
});

test("ADHOC: check fails a bundle whose executable is missing", () => {
  const { bin } = fakeTools();
  const { app } = assembled();
  run(["sign", app], {}, bin);
  Bun.spawnSync(["rm", join(app, "Contents/MacOS/Offload")]);
  const r = run(["check", app], {}, bin);
  expect(r.code).toBe(1);
  expect(r.out).toContain("MacOS/Offload");
});

test("ADHOC: check fails a Mach-O file under Resources (DEPLOYMENT 3.1)", () => {
  const { bin } = fakeTools();
  const { app } = assembled();
  writeFileSync(join(app, "Contents/Resources/helper"), Buffer.from([0xcf, 0xfa, 0xed, 0xfe, 0x0c, 0x00, 0x00, 0x01]));
  run(["sign", app], {}, bin);
  const r = run(["check", app], {}, bin);
  expect(r.code).toBe(1);
  expect(r.out).toContain("Mach-O under Resources");
  expect(r.out).toContain("helper");
});

test("ADHOC: check fails a bundle without its third-party notices file", () => {
  const { bin } = fakeTools();
  const { app } = assembled();
  Bun.spawnSync(["rm", join(app, "Contents/Resources/THIRD_PARTY_NOTICES.txt")]);
  run(["sign", app], {}, bin);
  const r = run(["check", app], {}, bin);
  expect(r.code).toBe(1);
  expect(r.out).toContain("THIRD_PARTY_NOTICES.txt");
});

test("ADHOC: check fails a bundle over the size budget", () => {
  const { bin } = fakeTools();
  const { app } = assembled();
  run(["sign", app], {}, bin);
  expect(run(["check", app], {}, bin).code).toBe(0);
  const r = run(["check", app], { BUNDLE_MAX_MB: "0" }, bin);
  expect(r.code).toBe(1);
  expect(r.out).toContain("size budget");
});

// ---- SMOKE ---------------------------------------------------------------

function smokeApp(line: (v: string) => string, code = 0) {
  const d = tmp();
  const bindir = join(d, "release");
  mkdirSync(bindir);
  const version = readFileSync(join(repo, "apps/mac/TestBuild/VERSION"), "utf8").trim();
  const envFile = join(d, "env.txt");
  const bin = fakeBinary(bindir, line(version), envFile, code);
  const { bin: tools } = fakeTools();
  run(["assemble", bin, join(d, "out")], { OFFLOAD_BUILD_NUMBER: "9", OFFLOAD_COMMIT: SHA });
  const app = join(d, "out", "Offload.app");
  run(["sign", app], {}, tools);
  return { app, envFile, tools };
}

test("SMOKE: the installed copy runs --version with an empty environment and a temp HOME, and passes", () => {
  const { app, envFile, tools } = smokeApp((v) => `Offload ${v} (9) 0123456 ${BUNDLE_ID}`);
  // Markers in the caller's environment must not reach the app (review 1 finding 4: only env -i keeps them out).
  const r = run(["smoke", app], { OFFLOAD_PROBE: "1", SMOKE_LEAK_MARKER: "leaked" }, tools);
  expect(r.out + r.err).not.toContain("FAIL");
  expect(r.code).toBe(0);
  const env = readFileSync(envFile, "utf8");
  expect(env).not.toContain("OFFLOAD_PROBE");
  expect(env).not.toContain("leaked");
  expect(env).toContain("PATH=/usr/bin:/bin:/usr/sbin:/sbin");
  const home = env.match(/^HOME=(.*)$/m)?.[1] ?? "";
  expect(home).not.toBe(process.env["HOME"] ?? "");
  expect(home.length).toBeGreaterThan(0);
  expect(env).not.toMatch(/^OFFLOAD_/m);
  expect(env.split("\n").filter((l) => /^[A-Z_]+=/.test(l) && !l.startsWith("SELF=")).length).toBeLessThanOrEqual(6);
});

test("SMOKE: a binary that exits non-zero fails the smoke check", () => {
  const { app, tools } = smokeApp((v) => `Offload ${v} (9) 0123456 ${BUNDLE_ID}`, 3);
  const r = run(["smoke", app], {}, tools);
  expect(r.code).not.toBe(0);
  expect(r.out).toContain("FAIL");
});

test("SMOKE: a binary that prints the wrong version line fails the smoke check", () => {
  const { app, tools } = smokeApp(() => "Offload dev");
  const r = run(["smoke", app], {}, tools);
  expect(r.code).not.toBe(0);
  expect(r.out).toContain("FAIL");
});

test("SMOKE: the smoke check runs a copy, not the built bundle", () => {
  const { app, envFile, tools } = smokeApp((v) => `Offload ${v} (9) 0123456 ${BUNDLE_ID}`);
  run(["smoke", app], {}, tools);
  const self = readFileSync(envFile, "utf8").match(/^SELF=(.*)$/m)?.[1] ?? "";
  expect(self.endsWith("/Offload.app/Contents/MacOS/Offload")).toBe(true);
  expect(self.startsWith(app)).toBe(false);
  expect(existsSync(join(app, "Contents/MacOS/Offload"))).toBe(true);
});

// ---- PINNED --------------------------------------------------------------

function pinnedFixture() {
  const d = tmp();
  const src = join(d, "tool.tar");
  writeFileSync(src, "pinned tool bytes");
  const sum = createHash("sha256").update("pinned tool bytes").digest("hex");
  return { d, url: `file://${src}`, sum, out: join(d, "dl", "tool.tar") };
}

test("PINNED: a download whose checksum matches is kept", () => {
  const { url, sum, out } = pinnedFixture();
  const r = run(["fetch-pinned", url, sum, out]);
  expect(r.code).toBe(0);
  expect(readFileSync(out, "utf8")).toBe("pinned tool bytes");
});

test("PINNED: a download whose checksum does not match fails and is removed", () => {
  const { url, out } = pinnedFixture();
  const r = run(["fetch-pinned", url, "0".repeat(64), out]);
  expect(r.code).toBe(1);
  expect(r.err).toContain("checksum mismatch");
  expect(existsSync(out)).toBe(false);
});

test("PINNED: a checksum that is not 64 hex characters is refused before downloading", () => {
  const { url, out } = pinnedFixture();
  expect(run(["fetch-pinned", url, "abc", out]).code).toBe(2);
  expect(existsSync(out)).toBe(false);
});
