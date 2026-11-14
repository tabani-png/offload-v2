// BUNDLE: bundle.sh assembles Offload.app with the right Info.plist; check-bundle.sh enforces the DEPLOYMENT 3.1
// rules. Contract: slices/m3-03-mac-signing-sparkle/SPEC.md.
import { afterAll, expect, test } from "bun:test";
import { existsSync, lstatSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { MACHO, cleanup, fakeBuildDir, fakeCodesign, fixtureApp, parsePlist, readPackaging, runScript, tmp } from "./helpers";

afterAll(cleanup);

const ED_PUBLIC = "pZ1n3yXgq8m9VqfQb4Xr2c7k5Lw0oT6sJdHuA1eBvCY=";

function bundle(flavour: string, extra: Record<string, string> = {}) {
  const dir = tmp();
  const out = join(dir, "out");
  const r = runScript("bundle.sh", [flavour], {
    BUILD_DIR: fakeBuildDir(dir),
    OUT_DIR: out,
    OFFLOAD_VERSION: "1.2.3",
    OFFLOAD_BUILD_NUMBER: "42",
    ...extra,
  });
  return { r, app: join(out, "Offload.app"), dir };
}

function check(app: string, dir: string, env: Record<string, string> = {}) {
  const { bin } = fakeCodesign(dir);
  return runScript("check-bundle.sh", [app], { CODESIGN: bin, ...env });
}

test("BUNDLE: a good bundle passes the bundle check", () => {
  const dir = tmp();
  const r = check(fixtureApp(dir), dir);
  expect(r.code).toBe(0);
  expect(r.out).toContain("bundle check: ok");
});

test("BUNDLE: a Mach-O under Resources fails the bundle check", () => {
  const dir = tmp();
  const app = fixtureApp(dir);
  writeFileSync(join(app, "Contents/Resources/helper"), MACHO);
  const r = check(app, dir);
  expect(r.code).toBe(1);
  expect(r.all).toContain("Mach-O under Resources");
  expect(r.all).toContain("Resources/helper");
});

test("BUNDLE: an unsigned executable fails the bundle check", () => {
  const dir = tmp();
  const app = fixtureApp(dir);
  writeFileSync(join(app, "Contents/MacOS/Offload"), Buffer.concat([MACHO, Buffer.from("UNSIGNED")]));
  const r = check(app, dir);
  expect(r.code).toBe(1);
  expect(r.all).toContain("not signed");
  expect(r.all).toContain("MacOS/Offload");

  // A nested Sparkle helper counts too.
  const dir2 = tmp();
  const app2 = fixtureApp(dir2);
  writeFileSync(
    join(app2, "Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate"),
    Buffer.concat([MACHO, Buffer.from("UNSIGNED")]),
  );
  expect(check(app2, dir2).code).toBe(1);
});

test("BUNDLE: a missing third-party notices file fails the bundle check", () => {
  const dir = tmp();
  const app = fixtureApp(dir);
  rmSync(join(app, "Contents/Resources/THIRD_PARTY_NOTICES.txt"));
  const r = check(app, dir);
  expect(r.code).toBe(1);
  expect(r.all).toContain("THIRD_PARTY_NOTICES.txt");
});

test("BUNDLE: a bundle over the size budget fails the bundle check", () => {
  const dir = tmp();
  const app = fixtureApp(dir);
  writeFileSync(join(app, "Contents/Resources/big.bin"), Buffer.alloc(2 * 1024 * 1024, 7));
  const r = check(app, dir, { BUNDLE_MAX_MB: "1" });
  expect(r.code).toBe(1);
  expect(r.all).toContain("size budget");
  // The default budget (50 MB) lets the same bundle through.
  expect(check(app, dir).code).toBe(0);
});

test("BUNDLE: Info.plist has the bundle id, macOS 14.0 minimum, menu bar flag and the four Sparkle keys", () => {
  const { r, app } = bundle("release", {
    OFFLOAD_DOWNLOADS_HOST: "downloads.example.test",
    SPARKLE_ED_PUBLIC_KEY: ED_PUBLIC,
  });
  expect(r.code).toBe(0);
  const p = parsePlist(readFileSync(join(app, "Contents/Info.plist"), "utf8"));
  expect(p.CFBundleIdentifier).toBe("ai.offload.mac");
  expect(p.CFBundleExecutable).toBe("Offload");
  expect(p.CFBundleShortVersionString).toBe("1.2.3");
  expect(p.CFBundleVersion).toBe("42");
  expect(p.LSMinimumSystemVersion).toBe("14.0");
  expect(p.LSUIElement).toBe(true);
  expect(p.LSApplicationCategoryType).toBe("public.app-category.productivity");
  expect(p.NSScreenCaptureUsageDescription).toBe("Offload reads what's on screen, on this Mac, to understand your work.");
  expect(p.SUFeedURL).toBe("https://downloads.example.test/appcast.xml");
  expect(p.SUPublicEDKey).toBe(ED_PUBLIC);
  expect(p.SURequireSignedFeed).toBe(true);
  expect(p.SUVerifyUpdateBeforeExtraction).toBe(true);

  // Layout of DEPLOYMENT 3.1.
  const c = join(app, "Contents");
  expect(existsSync(join(c, "MacOS/Offload"))).toBe(true);
  expect(existsSync(join(c, "Frameworks/Sparkle.framework/Versions/B/Autoupdate"))).toBe(true);
  expect(lstatSync(join(c, "Frameworks/Sparkle.framework/Versions/Current")).isSymbolicLink()).toBe(true);
  expect(readFileSync(join(c, "Resources/THIRD_PARTY_NOTICES.txt"), "utf8")).toContain("Sparkle");
});

test("BUNDLE: a dev build gets the .dev bundle id and a missing downloads host leaves the feed keys out", () => {
  const { r, app } = bundle("dev", { SPARKLE_ED_PUBLIC_KEY: ED_PUBLIC });
  expect(r.code).toBe(0);
  expect(r.all).toContain("updates off in this build");
  const p = parsePlist(readFileSync(join(app, "Contents/Info.plist"), "utf8"));
  expect(p.CFBundleIdentifier).toBe("ai.offload.mac.dev");
  for (const k of ["SUFeedURL", "SUPublicEDKey", "SURequireSignedFeed", "SUVerifyUpdateBeforeExtraction"]) {
    expect(p[k]).toBeUndefined();
  }
  // A missing public key leaves them out as well.
  const noKey = bundle("release", { OFFLOAD_DOWNLOADS_HOST: "downloads.example.test" });
  expect(noKey.r.code).toBe(0);
  expect(parsePlist(readFileSync(join(noKey.app, "Contents/Info.plist"), "utf8")).SUFeedURL).toBeUndefined();
});

test("BUNDLE: bundle.sh refuses a malformed version, build number, host or flavour", () => {
  expect(bundle("release", { OFFLOAD_VERSION: "1.2" }).r.code).not.toBe(0);
  expect(bundle("release", { OFFLOAD_BUILD_NUMBER: "4a" }).r.code).not.toBe(0);
  expect(
    bundle("release", { OFFLOAD_DOWNLOADS_HOST: "evil.test/x<", SPARKLE_ED_PUBLIC_KEY: ED_PUBLIC }).r.code,
  ).not.toBe(0);
  expect(bundle("release", { SPARKLE_ED_PUBLIC_KEY: "<key/>", OFFLOAD_DOWNLOADS_HOST: "d.example.test" }).r.code).not.toBe(0);
  expect(bundle("staging").r.code).toBe(2);
});

test("BUNDLE: the entitlements file turns on nothing beyond the hardened runtime", () => {
  const ent = readPackaging("Offload.entitlements");
  expect(ent).toContain("<dict/>");
  expect(ent).not.toContain("<key>");
});
