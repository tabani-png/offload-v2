// RELEASE: the CI mac job, release-mac.yml and promote-mac.yml keep secrets to the six placeholder names, out of
// pull requests and out of run: text. Contract: slices/m3-03-mac-signing-sparkle/SPEC.md.
import { expect, test } from "bun:test";
import { existsSync, readdirSync } from "node:fs";
import { SECRET_NAMES, WORKFLOWS, readWorkflow, triggers } from "./helpers";

const files = () => readdirSync(WORKFLOWS).filter((f) => /\.ya?ml$/.test(f));
const steps = (job: any): any[] => job?.steps ?? [];
const runText = (s: any): string => (typeof s?.run === "string" ? s.run : "");
const envName = (job: any): string | undefined =>
  typeof job?.environment === "string" ? job.environment : job?.environment?.name;

test("RELEASE: every secret a workflow references is one of the six placeholder names", () => {
  expect(existsSync(`${WORKFLOWS}/release-mac.yml`)).toBe(true);
  let seen = 0;
  for (const f of files()) {
    const { text } = readWorkflow(f);
    for (const m of text.matchAll(/secrets\s*\.\s*([A-Za-z0-9_]+)|secrets\s*\[\s*['"]([^'"]+)['"]\s*\]/g)) {
      seen++;
      expect(SECRET_NAMES as readonly string[]).toContain(m[1] ?? m[2]);
    }
    // No dynamic or blanket access.
    expect(text).not.toMatch(/toJSON\(\s*secrets\s*\)|secrets\s*\[\s*[^'"\s]/);
    expect(text).not.toMatch(/secrets:\s*inherit/);
  }
  expect(seen).toBeGreaterThan(0);
});

test("RELEASE: no job that runs on pull_request references a secret", () => {
  let prWorkflows = 0;
  for (const f of files()) {
    const { text, doc } = readWorkflow(f);
    const on = triggers(doc);
    if (!("pull_request" in on) && !("pull_request_target" in on)) continue;
    prWorkflows++;
    expect("pull_request_target" in on).toBe(false);
    expect(text).not.toMatch(/secrets\s*[.[]|secrets:\s*inherit/);
  }
  expect(prWorkflows).toBeGreaterThan(0);
});

test("RELEASE: release-mac runs only in the release environment, on a tag or manual dispatch, on macos-26", () => {
  const { doc } = readWorkflow("release-mac.yml");
  const on = triggers(doc);
  expect(Object.keys(on).sort()).toEqual(["push", "workflow_dispatch"]);
  expect(on.push.tags).toEqual(["v*"]);
  expect(on.push.branches).toBeUndefined();
  expect(doc.permissions).toEqual({ contents: "read" });
  const jobs = Object.entries<any>(doc.jobs);
  expect(jobs.length).toBeGreaterThan(0);
  for (const [, job] of jobs) {
    expect(envName(job)).toBe("release");
    expect(job["runs-on"]).toBe("macos-26");
  }
  // contents: write only on the job that publishes.
  const writers = jobs.filter(([, j]) => j.permissions?.contents === "write");
  expect(writers.length).toBe(1);
  expect(writers[0]![0]).toBe("publish");
});

test("RELEASE: the temporary keychain is deleted in a step that always runs", () => {
  const { doc } = readWorkflow("release-mac.yml");
  const all = Object.values<any>(doc.jobs).flatMap(steps);
  const del = all.filter((s) => /security delete-keychain/.test(runText(s)));
  expect(del.length).toBeGreaterThan(0);
  for (const s of del) expect(String(s.if)).toMatch(/always\(\)/);
  // The signing step comes before the cleanup in the same job.
  const job = Object.values<any>(doc.jobs).find((j) => steps(j).some((s) => /sign\.sh[^\n]*developer-id/.test(runText(s))));
  const st = steps(job);
  const signAt = st.findIndex((s) => /sign\.sh[^\n]*developer-id/.test(runText(s)));
  const delAt = st.findIndex((s) => /security delete-keychain/.test(runText(s)));
  expect(signAt).toBeGreaterThan(-1);
  expect(delAt).toBeGreaterThan(signAt);
});

test("RELEASE: the secrets check exposes only true or false", () => {
  for (const f of files()) {
    const { doc } = readWorkflow(f);
    for (const job of Object.values<any>(doc.jobs)) {
      for (const s of steps(job)) expect(runText(s)).not.toMatch(/secrets\./);
      // Job outputs never carry a secret.
      for (const v of Object.values<any>(job.outputs ?? {})) expect(String(v)).not.toMatch(/secrets\./);
    }
  }
  const { doc } = readWorkflow("release-mac.yml");
  const build = Object.values<any>(doc.jobs).find((j) => steps(j).some((s) => s.id === "secrets"));
  const check = steps(build).find((s) => s.id === "secrets");
  expect(steps(build).indexOf(check)).toBeLessThan(3);
  const env = check.env ?? {};
  expect(Object.keys(env).sort()).toEqual(["HAS_NOTARY", "HAS_SIGNING", "HAS_SPARKLE"]);
  for (const v of Object.values<string>(env)) {
    // Each value is a comparison against the empty string, joined with &&: a boolean, never a value.
    const parts = v.replace(/^\$\{\{\s*|\s*\}\}$/g, "").split("&&").map((p) => p.trim());
    for (const p of parts) expect(p).toMatch(/^secrets\.[A-Z0-9_]+ != ''$/);
  }
  // Every step that is handed a secret is gated on the matching boolean, and has a sibling that prints the skip.
  for (const s of steps(build)) {
    const handed = Object.values<any>(s.env ?? {}).some((v) => /secrets\.[A-Z0-9_]+ }}$/.test(String(v)) && !/!=/.test(String(v)));
    if (!handed) continue;
    expect(String(s.if)).toMatch(/steps\.secrets\.outputs\.has_(signing|notary|sparkle) == 'true'/);
  }
  for (const k of ["has_signing", "has_notary", "has_sparkle"]) {
    const skip = steps(build).find((s) => String(s.if).includes(`steps.secrets.outputs.${k} != 'true'`));
    expect(skip).toBeDefined();
    expect(runText(skip)).toMatch(/skipped \(absent: /);
  }
});

test("RELEASE: the mac job uploads the bundle before any test step", () => {
  const { doc } = readWorkflow("ci.yml");
  const st = steps(doc.jobs.mac);
  const upload = st.findIndex((s) => String(s.uses ?? "").startsWith("actions/upload-artifact"));
  expect(upload).toBeGreaterThan(-1);
  expect(String(st[upload].with?.path)).toMatch(/\.zip/);
  const firstTest = st.findIndex((s) => /swift test|verify\.sh|--self-check/.test(runText(s)));
  expect(firstTest).toBeGreaterThan(upload);
  // Build, bundle, ad hoc sign and check come before the upload.
  const order = ["swift build -c release", "bundle.sh release", "sign.sh", "check-bundle.sh", "ditto -c -k"].map((n) =>
    st.findIndex((s) => runText(s).includes(n)),
  );
  for (const i of order) expect(i).toBeGreaterThan(-1);
  expect([...order].sort((a, b) => a - b)).toEqual(order);
  expect(order.at(-1)!).toBeLessThan(upload);
  expect(runText(st[order[2]!])).toContain("adhoc");
  // The installed-copy smoke test runs from a ditto copy with an empty environment.
  const smoke = st.find((s) => runText(s).includes("--self-check"));
  expect(runText(smoke)).toContain("env -i HOME=");
  expect(runText(smoke)).toContain("PATH=/usr/bin:/bin:/usr/sbin:/sbin");
  expect(runText(smoke)).toMatch(/ditto /);
  // Each suite is its own step with a timeout and continue-on-error, and the result step fails on any of them.
  const suites = st.filter((s) => /swift test|verify\.sh/.test(runText(s)));
  expect(suites.some((s) => runText(s).includes("slices/m3-03-mac-signing-sparkle/verify.sh"))).toBe(true);
  for (const s of suites) {
    expect(s["continue-on-error"]).toBe(true);
    expect(s["timeout-minutes"]).toBeGreaterThan(0);
    expect(typeof s.id).toBe("string");
  }
  const result = st.at(-1);
  expect(String(result.if)).toContain("always()");
  for (const s of suites) expect(runText(result)).toContain(`steps.${s.id}.outcome`);
  expect(st.some((s) => runText(s).includes("developer id signing: runs in release-mac.yml"))).toBe(true);
});

test("RELEASE: the mac job runs only when apps/mac, packages/contracts or the workflows change", () => {
  const { doc } = readWorkflow("ci.yml");
  const mac = doc.jobs.mac;
  const needs = Array.isArray(mac.needs) ? mac.needs : [mac.needs];
  expect(needs).toContain("changes");
  expect(String(mac.if)).toContain("needs.changes.outputs.mac == 'true'");
  const text = steps(doc.jobs.changes).map(runText).join("\n");
  for (const p of ["apps/mac/", "packages/contracts/", ".github/workflows/"]) expect(text).toContain(p);
});

test("RELEASE: promote-mac is manual only and offers promote, halt and rerelease", () => {
  const { doc } = readWorkflow("promote-mac.yml");
  const on = triggers(doc);
  expect(Object.keys(on)).toEqual(["workflow_dispatch"]);
  const inputs = on.workflow_dispatch.inputs;
  expect(inputs.action.type).toBe("choice");
  expect([...inputs.action.options].sort()).toEqual(["halt", "promote", "rerelease"]);
  expect(inputs.version.required).toBe(true);
  for (const job of Object.values<any>(doc.jobs)) expect(envName(job)).toBe("release");
});
