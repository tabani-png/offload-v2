import { afterAll, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const script = join(import.meta.dir, "..", "check-workflows.ts");
const dirs: string[] = [];
afterAll(() => dirs.forEach((d) => rmSync(d, { recursive: true, force: true })));

function run(files: Record<string, string>): number {
  const root = mkdtempSync(join(tmpdir(), "wf-"));
  dirs.push(root);
  mkdirSync(join(root, ".github/workflows"), { recursive: true });
  for (const [name, body] of Object.entries(files)) writeFileSync(join(root, ".github/workflows", name), body);
  return Bun.spawnSync(["bun", script, root], { stdout: "pipe", stderr: "pipe" }).exitCode;
}

const good = "name: ci\non: push\njobs:\n  a:\n    runs-on: ubuntu-24.04\n    steps:\n      - run: |\n          echo \"a: b\"\n";

test("WORKFLOW: a valid workflow passes", () => {
  expect(run({ "ci.yml": good })).toBe(0);
});

test("WORKFLOW: a plain scalar with ': ' inside fails to parse", () => {
  expect(run({ "ci.yml": good.replace('run: |\n          echo "a: b"', 'run: echo "a: b"') })).toBe(1);
});

test("WORKFLOW: a workflow without jobs fails", () => {
  expect(run({ "ci.yml": "name: ci\non: push\n" })).toBe(1);
});

// Slice verify.sh diffs BASE..HEAD, so a shallow checkout fails with "BASE <sha> not found" once a slice is done.
// SLICE_UPSTREAM keeps changes that reached main after BASE out of the slice's scope check.
const upstreamEnv = "        env:\n          SLICE_UPSTREAM: ${{ github.event.before }}\n";
const slicesJob = (checkout: string, stepEnv = upstreamEnv) =>
  `name: ci\non: push\njobs:\n  a:\n    runs-on: ubuntu-24.04\n    steps:\n${checkout}      - run: bash scripts/check-slices.sh\n${stepEnv}`;

test("WORKFLOW: a job running slice checks with a shallow checkout fails", () => {
  expect(run({ "ci.yml": slicesJob("      - uses: actions/checkout@v4\n") })).toBe(1);
});

test("WORKFLOW: a job running slice checks with fetch-depth 0 passes", () => {
  expect(run({ "ci.yml": slicesJob("      - uses: actions/checkout@v4\n        with:\n          fetch-depth: 0\n") })).toBe(0);
});

test("WORKFLOW: a job running a slice verify.sh with a shallow checkout fails", () => {
  const body = slicesJob("      - uses: actions/checkout@v4\n").replace(
    "bash scripts/check-slices.sh", "bash slices/x/verify.sh");
  expect(run({ "ci.yml": body })).toBe(1);
});

test("WORKFLOW: a slice check step without SLICE_UPSTREAM fails", () => {
  expect(run({ "ci.yml": slicesJob("      - uses: actions/checkout@v4\n        with:\n          fetch-depth: 0\n", "") })).toBe(1);
});
