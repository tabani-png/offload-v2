import { afterAll, expect, test } from "bun:test";
import { chmodSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const script = join(import.meta.dir, "..", "check-slices.sh");
const template = readFileSync(join(import.meta.dir, "..", "..", "slices", "_template", "verify.sh"), "utf8");
const dirs: string[] = [];
afterAll(() => dirs.forEach((d) => rmSync(d, { recursive: true, force: true })));

type Spec = Record<string, string>;

function spec(id: string, over: Spec = {}): Spec {
  return {
    id,
    title: "A slice",
    milestone: "M1",
    status: "ready",
    depends_on: "[]",
    parallel_safe: "false",
    human_gated: "false",
    model_tier: "sonnet",
    size: "M",
    parallel_group: "A1",
    owns: "[]",
    verify: `bash slices/${id}/verify.sh`,
    min_tests: "1",
    paths_in_scope: `[packages/a/**, slices/${id}/**]`,
    paths_out_of_scope: "[ee/**]",
    red_tests: "[EXAMPLE]",
    ...over,
  };
}

function verifyFor(id: string, base = ""): string {
  return template.replace('SLICE_ID="_template"', `SLICE_ID="${id}"`).replace('BASE=""', `BASE="${base}"`);
}

function fixture(slices: Record<string, { spec: Spec; verify?: string }>): string {
  const root = mkdtempSync(join(tmpdir(), "slices-"));
  dirs.push(root);
  for (const [name, s] of Object.entries(slices)) {
    const dir = join(root, "slices", name);
    mkdirSync(dir, { recursive: true });
    const fm = Object.entries(s.spec).map(([k, v]) => `${k}: ${v}`).join("\n");
    writeFileSync(join(dir, "SPEC.md"), `---\n${fm}\n---\n\n# ${name}\n`);
    writeFileSync(join(dir, "verify.sh"), s.verify ?? verifyFor(name));
    chmodSync(join(dir, "verify.sh"), 0o755);
  }
  return root;
}

function run(root: string) {
  const r = Bun.spawnSync(["bash", script, root], { stdout: "pipe", stderr: "pipe" });
  return { code: r.exitCode, err: r.stderr.toString() };
}

test("SLICES: a well-formed slice passes", () => {
  expect(run(fixture({ "m1-01-a": { spec: spec("m1-01-a") } })).code).toBe(0);
});

test("SLICES: a missing task field fails", () => {
  const s = spec("m1-01-a");
  delete s["model_tier"];
  const r = run(fixture({ "m1-01-a": { spec: s } }));
  expect(r.code).toBe(1);
  expect(r.err).toContain("model_tier");
});

test("SLICES: a bad model tier, size or parallel group fails", () => {
  expect(run(fixture({ "m1-01-a": { spec: spec("m1-01-a", { model_tier: "gpt" }) } })).code).toBe(1);
  expect(run(fixture({ "m1-01-a": { spec: spec("m1-01-a", { size: "XL" }) } })).code).toBe(1);
  expect(run(fixture({ "m1-01-a": { spec: spec("m1-01-a", { parallel_group: "" }) } })).code).toBe(1);
});

test("SLICES: depends_on must name existing slices", () => {
  const r = run(fixture({ "m1-02-b": { spec: spec("m1-02-b", { depends_on: "[m1-01-gone]" }) } }));
  expect(r.code).toBe(1);
  expect(r.err).toContain("m1-01-gone");
});

test("SLICES: verify must be bash slices/<id>/verify.sh", () => {
  const r = run(fixture({ "m1-01-a": { spec: spec("m1-01-a", { verify: "bun test" }) } }));
  expect(r.code).toBe(1);
});

test("SLICES: verify.sh must read its config from the SPEC", () => {
  const v = verifyFor("m1-01-a").replace('MIN_TESTS="$(fm min_tests)"', 'MIN_TESTS="3"');
  const r = run(fixture({ "m1-01-a": { spec: spec("m1-01-a"), verify: v } }));
  expect(r.code).toBe(1);
  expect(r.err).toContain("MIN_TESTS");
});

test("SLICES: verify.sh SLICE_ID must match the folder", () => {
  const r = run(fixture({ "m1-01-a": { spec: spec("m1-01-a"), verify: verifyFor("m1-09-other") } }));
  expect(r.code).toBe(1);
});

test("SLICES: an in_progress slice needs BASE", () => {
  const r = run(fixture({ "m1-01-a": { spec: spec("m1-01-a", { status: "in_progress" }) } }));
  expect(r.code).toBe(1);
  expect(r.err).toContain("BASE");
});

test("SLICES: done slices run verify.sh with SKIP_FULL_SUITE=1", () => {
  const out = join(mkdtempSync(join(tmpdir(), "slices-out-")), "env");
  dirs.push(join(out, ".."));
  const probe = [
    "#!/usr/bin/env bash",
    'SLICE_ID="m1-01-a"',
    'BASE="abc123"',
    "fm() { :; }; list() { :; }",
    'MIN_TESTS="$(fm min_tests)"',
    'TAGS="$(list red_tests)"',
    "IN_SCOPE=\"$(list paths_in_scope | sed 's#\\*\\*#*#g')\"",
    "OUT_OF_SCOPE=\"$(list paths_out_of_scope | sed 's#\\*\\*#*#g')\"",
    `echo "\${SKIP_FULL_SUITE:-}" > ${out}`,
    "",
  ].join("\n");
  const root = fixture({ "m1-01-a": { spec: spec("m1-01-a", { status: "done" }), verify: probe } });
  expect(run(root).code).toBe(0);
  expect(readFileSync(out, "utf8").trim()).toBe("1");
});
