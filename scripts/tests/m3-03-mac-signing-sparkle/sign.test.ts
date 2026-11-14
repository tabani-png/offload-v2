// SIGN: Developer ID signing, notarization and appcast scripts skip cleanly without their secrets, never print a
// secret, and sign inside-out with the hardened runtime. Contract: slices/m3-03-mac-signing-sparkle/SPEC.md.
import { afterAll, expect, test } from "bun:test";
import { existsSync, readFileSync, readdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import {
  PKG,
  SECRET_NAMES,
  cleanup,
  fakeBuildDir,
  fakeCodesign,
  fixtureApp,
  readPackaging,
  runEmptyEnv,
  runScript,
  tmp,
} from "./helpers";

afterAll(cleanup);

const scripts = () => readdirSync(PKG).filter((f) => f.endsWith(".sh"));
/** Script text without comment lines, so a comment that says "never --deep" is not a call. */
const code = (name: string) =>
  readPackaging(name)
    .split("\n")
    .filter((l) => !/^\s*#/.test(l))
    .join("\n");

test("SIGN: developer-id signing without its secrets prints the names it lacks and exits 0", () => {
  const app = fixtureApp(tmp());
  const r = runEmptyEnv("sign.sh", [app, "developer-id"]);
  expect(r.code).toBe(0);
  expect(r.out.trim()).toBe("signing: skipped (absent: DEVELOPER_ID_P12_BASE64 DEVELOPER_ID_P12_PASSWORD)");

  // Only one of the two present: still skipped, and only the missing name is listed.
  const one = runScript("sign.sh", [app, "developer-id"], { DEVELOPER_ID_P12_BASE64: "CANARY-only-one" });
  expect(one.code).toBe(0);
  expect(one.out.trim()).toBe("signing: skipped (absent: DEVELOPER_ID_P12_PASSWORD)");
  expect(one.all).not.toContain("CANARY");
});

test("SIGN: no packaging script prints a secret value", () => {
  const dir = tmp();
  const { bin } = fakeCodesign(dir);
  const canaries: Record<string, string> = {};
  for (const n of SECRET_NAMES) canaries[n] = `CANARY-${n}-9f2c41d7e0`;
  // Base64 of a canary too, so a decoded value would be caught as well as the raw one.
  canaries.DEVELOPER_ID_P12_BASE64 = Buffer.from("CANARY-P12-DECODED-5b1e").toString("base64");
  const env = { ...canaries, CODESIGN: bin, PACKAGING_OS: "Linux", HOME: dir, TMPDIR: dir };
  const needles = [...Object.values(canaries), "CANARY-P12-DECODED-5b1e", "CANARY"];

  const app = fixtureApp(join(dir, "a"));
  const zip = join(dir, "Offload-1.2.3.zip");
  writeFileSync(zip, "zip");
  const runs = [
    { r: runScript("sign.sh", [app, "developer-id"], env), code: 1, line: "signing: needs macOS" },
    { r: runScript("sign.sh", [app, "adhoc"], env), code: 0 },
    { r: runScript("notarize.sh", [app, "1.2.3"], env), code: 1, line: "notarization: needs macOS" },
    {
      r: runScript("appcast.sh", [zip, "1.2.3", "beta"], { ...env, OFFLOAD_DOWNLOADS_HOST: "downloads.example.test" }),
      code: 1,
      line: "appcast: needs macOS",
    },
    {
      r: runScript("bundle.sh", ["release"], {
        ...env,
        BUILD_DIR: fakeBuildDir(join(dir, "b")),
        OUT_DIR: join(dir, "out"),
        OFFLOAD_VERSION: "1.2.3",
        OFFLOAD_BUILD_NUMBER: "7",
      }),
      code: 0,
    },
    { r: runScript("check-bundle.sh", [app], env), code: 0 },
  ];
  for (const { r, code: want, line } of runs) {
    for (const n of needles) expect(r.all).not.toContain(n);
    expect(r.code).toBe(want);
    if (line) expect(r.all).toContain(line);
  }
});

test("SIGN: notarize skips cleanly without the App Store Connect secrets", () => {
  const app = fixtureApp(tmp());
  const r = runEmptyEnv("notarize.sh", [app, "1.2.3"]);
  expect(r.code).toBe(0);
  expect(r.out.trim()).toBe("notarization: skipped (absent: ASC_KEY_ID ASC_ISSUER_ID ASC_KEY_P8)");
  expect(r.err).toBe("");
});

test("SIGN: appcast skips cleanly without the Sparkle private key", () => {
  const dir = tmp();
  const zip = join(dir, "Offload-1.2.3.zip");
  writeFileSync(zip, "zip");
  const r = runEmptyEnv("appcast.sh", [zip, "1.2.3", "beta"]);
  expect(r.code).toBe(0);
  expect(r.out.trim()).toBe("appcast: skipped (absent: SPARKLE_ED_PRIVATE_KEY)");
  expect(r.err).toBe("");
});

test("SIGN: signing is inside-out and never uses --deep", () => {
  for (const s of scripts()) expect(code(s)).not.toContain("--deep");
  const sign = code("sign.sh");
  const order = [
    sign.indexOf("XPCServices"),
    sign.indexOf("sign_one \"$FW/Versions/B/Autoupdate\""),
    sign.indexOf("sign_one \"$FW/Versions/B/Updater.app\""),
    sign.indexOf("sign_one \"$FW\""),
    sign.indexOf("sign_one \"$APP\""),
  ];
  for (const i of order) expect(i).toBeGreaterThan(-1);
  expect([...order].sort((a, b) => a - b)).toEqual(order);

  // The same order, observed through a fake codesign in ad hoc mode.
  const dir = tmp();
  const { bin, log } = fakeCodesign(dir);
  const app = fixtureApp(dir);
  const r = runScript("sign.sh", [app, "adhoc"], { CODESIGN: bin });
  expect(r.code).toBe(0);
  const calls = readFileSync(log, "utf8").trim().split("\n");
  const targets = calls.map((c) => c.split(" ").at(-1)!.replace(dir + "/", ""));
  expect(targets).toEqual([
    "Offload.app/Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate",
    "Offload.app/Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app",
    "Offload.app/Contents/Frameworks/Sparkle.framework",
    "Offload.app",
  ]);
  for (const c of calls) expect(c).not.toContain("--deep");
  // Sparkle's XPC services are removed before signing (the app is not sandboxed).
  expect(existsSync(join(app, "Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices"))).toBe(false);
  expect(existsSync(join(app, "Contents/Frameworks/Sparkle.framework/XPCServices"))).toBe(false);
  // The app is signed with the entitlements file.
  expect(calls.at(-1)).toContain("--entitlements");
  expect(calls.at(-1)).toContain("Offload.entitlements");
});

test("SIGN: every codesign call uses --options runtime --timestamp", () => {
  let signing = 0;
  for (const s of scripts()) {
    for (const line of code(s).split("\n")) {
      if (!/\bCODESIGN\b|\bcodesign\b/.test(line) || !/--sign\b/.test(line)) continue;
      signing++;
      expect(line).toContain("--options runtime");
      expect(line).toContain("--timestamp");
    }
  }
  expect(signing).toBeGreaterThanOrEqual(2); // sign.sh's sign_one and the disk image in notarize.sh

  const dir = tmp();
  const { bin, log } = fakeCodesign(dir);
  expect(runScript("sign.sh", [fixtureApp(dir), "adhoc"], { CODESIGN: bin }).code).toBe(0);
  for (const c of readFileSync(log, "utf8").trim().split("\n")) {
    expect(c).toContain("--options runtime");
    expect(c).toContain("--timestamp");
  }
});

test("SIGN: the Sparkle tools archive is refused when its checksum does not match the pin", () => {
  const dir = tmp();
  const archive = join(dir, "Sparkle-2.10.1.tar.xz");
  writeFileSync(archive, "not the real archive");
  const dest = join(dir, "tools");
  const r = runScript("fetch-sparkle-tools.sh", [dest], { SPARKLE_TOOLS_URL: `file://${archive}`, TMPDIR: dir });
  expect(r.code).toBe(1);
  expect(r.all).toContain("checksum mismatch");
  expect(existsSync(join(dest, "bin"))).toBe(false);
  // The pin is the digest GitHub publishes for the 2.10.1 release archive.
  expect(readPackaging("fetch-sparkle-tools.sh")).toContain(
    "1a856d2a9edb8e628de88121d7be04cf0e2167f8641650b78fca00b14244cf27",
  );
});

test("SIGN: an unknown signing mode is refused", () => {
  const r = runScript("sign.sh", [fixtureApp(tmp()), "deep"], {});
  expect(r.code).toBe(2);
  expect(r.all).toContain("usage");
});
