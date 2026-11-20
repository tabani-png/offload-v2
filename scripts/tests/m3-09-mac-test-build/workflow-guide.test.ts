import { afterAll, expect, test } from "bun:test";
import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { cleanup, guide, repo, script, workflow } from "./helpers";

afterAll(cleanup);

type Step = { name?: string; id?: string; uses?: string; run?: string; if?: string; env?: Record<string, string>;
  "continue-on-error"?: boolean; with?: Record<string, unknown> };
function load(): any {
  return Bun.YAML.parse(readFileSync(workflow, "utf8"));
}
function steps(): Step[] {
  const jobs = Object.values<any>(load().jobs);
  expect(jobs.length).toBe(1);
  return jobs[0].steps as Step[];
}

// ---- ARTIFACT ------------------------------------------------------------

test("ARTIFACT: mac-artifact runs on push to the W1-H branch, on pull requests and by hand, on macos-26", () => {
  const w = load();
  expect(w.on.push.branches).toContain("w1/h-shell-onboarding");
  expect("pull_request" in w.on).toBe(true);
  expect("workflow_dispatch" in w.on).toBe(true);
  const job = Object.values<any>(w.jobs)[0];
  expect(job["runs-on"]).toBe("macos-26");
  expect(job["timeout-minutes"]).toBeGreaterThan(0);
});

test("ARTIFACT: the workflow reads the repo only and references no secret", () => {
  const text = readFileSync(workflow, "utf8");
  const w = load();
  expect(w.permissions).toEqual({ contents: "read" });
  expect(text).not.toMatch(/secrets\./);
  expect(text).not.toMatch(/GITHUB_TOKEN/);
});

test("ARTIFACT: build, smoke check, then upload of the stamped zip and the guide for 14 days", () => {
  const s = steps();
  const build = s.findIndex((x) => x.run?.includes("build-app.sh all"));
  const smoke = s.findIndex((x) => x.run?.includes("build-app.sh smoke"));
  const upload = s.findIndex((x) => x.uses?.startsWith("actions/upload-artifact@"));
  expect(build).toBeGreaterThanOrEqual(0);
  expect(smoke).toBeGreaterThan(build);
  expect(upload).toBeGreaterThan(smoke);
  const w = (s[upload]?.with ?? {}) as Record<string, any>;
  expect(String(w["name"])).toMatch(/^Offload-mac-\$\{\{ *steps\.\w+\.outputs\.\w+ *\}\}$/);
  expect(String(w["path"])).toContain("Offload-mac-");
  expect(String(w["path"])).toContain(".zip");
  expect(String(w["path"])).toContain("INSTALL_AND_TEST.md");
  expect(Number(w["retention-days"])).toBe(14);
  expect(w["if-no-files-found"]).toBe("error");
});

test("ARTIFACT: the upload still runs when the smoke check fails, and the job then fails", () => {
  const s = steps();
  const upload = s.find((x) => x.uses?.startsWith("actions/upload-artifact@"))!;
  const build = s.find((x) => x.run?.includes("build-app.sh all"))!;
  const smoke = s.find((x) => x.run?.includes("build-app.sh smoke"))!;
  expect(build.id).toBeTruthy();
  expect(smoke.id).toBeTruthy();
  expect(smoke["continue-on-error"]).toBe(true);
  expect(String(upload.if)).toContain(`steps.${build.id}.outcome == 'success'`);
  const last = s[s.length - 1]!;
  expect(String(last.if)).toContain("always()");
  expect(last.run).toContain(`steps.${smoke.id}.outcome`);
});

test("ARTIFACT: no test step runs before the upload", () => {
  const s = steps();
  const upload = s.findIndex((x) => x.uses?.startsWith("actions/upload-artifact@"));
  for (const x of s.slice(0, upload)) {
    expect(x.run ?? "").not.toMatch(/swift test|verify(-all)?\.sh|bun test/);
  }
});

test("ARTIFACT: actions are pinned the way ci.yml pins them and the toolchain is the newest Xcode", () => {
  const ci = readFileSync(join(repo, ".github/workflows/ci.yml"), "utf8");
  const pinned = new Set([...ci.matchAll(/uses: (\S+)/g)].map((m) => (m[1] ?? "").split("@")[0] + "@v"));
  pinned.add("actions/upload-artifact@v");
  for (const x of steps().filter((x) => x.uses)) {
    expect(x.uses).toMatch(/@(v\d+|[0-9a-f]{40})$/);
    expect(pinned.has(x.uses!.split("@")[0] + "@v")).toBe(true);
  }
  const tool = steps().find((x) => x.run?.includes("xcode-select -s"));
  expect(tool?.run).toContain("/Applications/Xcode*.app");
});

test("ARTIFACT: the build step stamps the commit and run number and never bundles bun or the brain", () => {
  const build = steps().find((x) => x.run?.includes("build-app.sh all"))!;
  expect(String(build.env?.["OFFLOAD_COMMIT"])).toContain("github.sha");
  expect(String(build.env?.["OFFLOAD_BUILD_NUMBER"])).toContain("github.run_number");
  const text = readFileSync(workflow, "utf8") + readFileSync(script, "utf8");
  expect(text).not.toMatch(/setup-bun|Helpers\/bun|brain-check|bundle_brain/);
});

test("ARTIFACT: build-app.sh is Bash 3.2 safe, strict, and never traces", () => {
  const src = readFileSync(script, "utf8");
  expect(src).toContain("set -euo pipefail");
  expect(src).not.toMatch(/^\s*set -[a-z]*x/m);
  expect(src).not.toMatch(/declare -A|mapfile|readarray|\$\{[A-Za-z_]+(,,|\^\^)\}|&>>|\|&/);
  expect(Bun.spawnSync(["bash", "-n", script]).exitCode).toBe(0);
});

test("ARTIFACT: pull requests build only when the app or this workflow changed; pushes and manual runs always build", () => {
  const w = load();
  expect(w.on.pull_request.paths).toEqual(["apps/mac/**", ".github/workflows/mac-artifact.yml"]);
  expect(w.on.push.paths).toBeUndefined();
  expect(w.on.workflow_dispatch?.paths).toBeUndefined();
});

test("ARTIFACT: a pull request build names the pull request head next to the merge commit it built", () => {
  const names = steps().find((x) => x.id === "names")!;
  expect(String(names.env?.["PR_HEAD"])).toBe("${{ github.event.pull_request.head.sha }}");
  expect(names.run).toContain("GITHUB_STEP_SUMMARY");
  expect(names.run).toContain("$PR_HEAD");
  // Event values reach run: text only through env, never as ${{ }} inside the script.
  for (const x of steps()) expect(x.run ?? "").not.toContain("github.event");
});

// ---- GUIDE ---------------------------------------------------------------

test("GUIDE: the install guide covers download, first open, permissions, what to expect, logs and uninstall", () => {
  expect(existsSync(guide)).toBe(true);
  const g = readFileSync(guide, "utf8");
  for (const h of [/^## .*Download/m, /^## .*first time/m, /^## .*Permissions/m, /^## .*expect/m, /^## .*logs/m, /^## .*(Uninstall|Remove)/m]) {
    expect(g).toMatch(h);
  }
  expect(g).toContain("Offload-mac-");
  expect(g).toContain("mac-artifact");
  expect(g).toMatch(/right-click/i);
  expect(g).toContain("Open Anyway");
  expect(g).toContain("--version");
  expect(g).toContain("ai.offload.mac.dev");
  expect(g).toContain("tccutil reset");
});

test("GUIDE: uninstall removes the bundle id folders DEPLOYMENT section 2 names, not a plain Offload folder", () => {
  const g = readFileSync(guide, "utf8");
  expect(g).toContain("~/Library/Application\\ Support/ai.offload.mac.dev");
  expect(g).not.toMatch(/Application\\? Support\/Offload\b/);
});

test("GUIDE: on macOS 15 and later the first open goes through Open Anyway; right-click Open is for macOS 14", () => {
  const g = readFileSync(guide, "utf8");
  const first = g.slice(g.indexOf("## 2."), g.indexOf("## 3."));
  expect(first).toContain("macOS 15");
  expect(first.indexOf("Open Anyway")).toBeGreaterThanOrEqual(0);
  expect(first.indexOf("Open Anyway")).toBeLessThan(first.search(/right-click/i));
  expect(first).toMatch(/macOS 14[^\n]*right-click|right-click[^\n]*macOS 14/i);
});

test("GUIDE: the download step works for browsers that keep the outer zip", () => {
  const g = readFileSync(guide, "utf8");
  const dl = g.slice(g.indexOf("## 1."), g.indexOf("## 2."));
  expect(dl).toContain("Safari");
  expect(dl).toMatch(/zip of the same name|inner zip|zip inside/i);
});

test("GUIDE: the guide says watching and Never watch start with a later build, and claims no capture now", () => {
  const g = readFileSync(guide, "utf8");
  expect(g).not.toMatch(/shows your real apps/);
  expect(g).not.toMatch(/are always excluded;/);
  expect(g).toMatch(/take effect when capture lands/);
  expect(g).toMatch(/[Ww]atching starts with a later (update|build)/);
});

test("GUIDE: the guide says a pull request build carries GitHub's merge commit", () => {
  const g = readFileSync(guide, "utf8");
  expect(g).toMatch(/pull request/i);
  expect(g).toMatch(/merge commit/);
});

test("GUIDE: the guide links DEPLOYMENT section 5 for the notarized build", () => {
  const g = readFileSync(guide, "utf8");
  expect(g).toContain("../../../docs/DEPLOYMENT.md#5-install-and-test-guide");
});

test("GUIDE: the guide uses no dry-run terms, banned words, em dashes or the old brain steps", () => {
  const g = readFileSync(guide, "utf8");
  expect(g).not.toMatch(/dry[ _-]?run|preview run/i);
  expect(g).not.toMatch(/\b(generous|unlock|seamless|powerful|robust)\b/i);
  expect(g).not.toContain("—");
  expect(g).not.toMatch(/brain-check|Claude key|Helpers\/bun|screenwatch/i);
});
