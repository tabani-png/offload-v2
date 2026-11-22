import { afterAll, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";

// scripts/lib/slice-changes.sh against a repo shaped like a GitHub pull_request checkout: HEAD is a merge commit
// whose first parent is main (which moved on after BASE) and whose second parent is the slice branch.
const lib = join(import.meta.dir, "..", "lib", "slice-changes.sh");
const dirs: string[] = [];
afterAll(() => dirs.forEach((d) => rmSync(d, { recursive: true, force: true })));

// SLICE_UPSTREAM is set by CI and by local verify runs; each test must choose it itself, so drop the ambient value.
const { SLICE_UPSTREAM: _ambientUpstream, ...cleanEnv } = process.env;
const env = {
  ...cleanEnv,
  GIT_AUTHOR_NAME: "t", GIT_AUTHOR_EMAIL: "t@example.invalid",
  GIT_COMMITTER_NAME: "t", GIT_COMMITTER_EMAIL: "t@example.invalid",
  GIT_CONFIG_GLOBAL: "/dev/null", GIT_CONFIG_NOSYSTEM: "1",
};

function git(cwd: string, ...args: string[]): string {
  const r = Bun.spawnSync(["git", ...args], { cwd, env, stdout: "pipe", stderr: "pipe" });
  if (r.exitCode !== 0) throw new Error(`git ${args.join(" ")}: ${r.stderr.toString()}`);
  return r.stdout.toString().trim();
}

function commit(cwd: string, files: Record<string, string>, msg: string): string {
  for (const [p, body] of Object.entries(files)) {
    mkdirSync(join(cwd, dirname(p)), { recursive: true });
    writeFileSync(join(cwd, p), body);
  }
  git(cwd, "add", "-A");
  git(cwd, "commit", "-q", "-m", msg);
  return git(cwd, "rev-parse", "HEAD");
}

const doneSpec = "---\nid: s1\nstatus: done\n---\n";

function prMergeRepo(opts: { doneOnMain?: boolean } = {}) {
  const root = mkdtempSync(join(tmpdir(), "slice-changes-"));
  dirs.push(root);
  git(root, "init", "-q", "-b", "main");
  const base = commit(root, { "README.md": "a\n" }, "base");
  git(root, "checkout", "-q", "-b", "slice");
  commit(root, { "packages/a/x.ts": "x\n" }, "s1: work");
  git(root, "checkout", "-q", "main");
  commit(root, { "README.md": "b\n", ...(opts.doneOnMain ? { "slices/s1/SPEC.md": doneSpec } : {}) }, "other PR");
  git(root, "merge", "-q", "--no-ff", "-m", "merge", "slice");
  return { root, base };
}

function files(root: string, base: string, extra: Record<string, string> = {}) {
  const r = Bun.spawnSync(
    ["bash", "-c", `. "${lib}"; SLICE_ID=s1; slice_files "$1"; echo "rc=$?"; printf '%s\\n' "$SLICE_FILES"`, "x", base],
    { cwd: root, env: { ...env, ...extra }, stdout: "pipe", stderr: "pipe" },
  );
  const out = r.stdout.toString().trim().split("\n");
  const i = out.findIndex((l) => l.startsWith("rc="));
  return { rc: out[i], files: out.slice(i + 1).filter(Boolean) };
}

test("SCOPE: without SLICE_UPSTREAM every change since BASE counts (local runs)", () => {
  const { root, base } = prMergeRepo();
  expect(files(root, base)).toEqual({ rc: "rc=0", files: ["README.md", "packages/a/x.ts"] });
});

test("SCOPE: with SLICE_UPSTREAM only commits not on upstream count (PR merge commit)", () => {
  const { root, base } = prMergeRepo();
  expect(files(root, base, { SLICE_UPSTREAM: "HEAD^1" })).toEqual({ rc: "rc=0", files: ["packages/a/x.ts"] });
});

test("SCOPE: an all-zero SLICE_UPSTREAM (first push) is treated as unset", () => {
  const { root, base } = prMergeRepo();
  expect(files(root, base, { SLICE_UPSTREAM: "0".repeat(40) }).files).toEqual(["README.md", "packages/a/x.ts"]);
});

test("SCOPE: a slice already done on upstream has no changes to check", () => {
  const { root, base } = prMergeRepo({ doneOnMain: true });
  expect(files(root, base, { SLICE_UPSTREAM: "HEAD^1" })).toEqual({ rc: "rc=0", files: [] });
});

test("SCOPE: an unknown SLICE_UPSTREAM is an error", () => {
  const { root, base } = prMergeRepo();
  expect(files(root, base, { SLICE_UPSTREAM: "f".repeat(40) }).rc).toBe("rc=1");
});

// Stacked slices on one branch: s1 is built and marked done, then s2 is built on top of it.
const spec = (id: string, status: string) => `---\nid: ${id}\nstatus: ${status}\n---\n`;

function stackedRepo(opts: { s1Extra?: Record<string, string> } = {}) {
  const root = mkdtempSync(join(tmpdir(), "slice-changes-stacked-"));
  dirs.push(root);
  git(root, "init", "-q", "-b", "main");
  const base = commit(root, { "README.md": "a\n", "slices/s1/SPEC.md": spec("s1", "ready"), "slices/s2/SPEC.md": spec("s2", "ready") }, "base");
  commit(root, { "slices/s1/SPEC.md": spec("s1", "in_progress") }, "s1: start");
  commit(root, { "packages/a/x.ts": "x\n", ...(opts.s1Extra ?? {}) }, "s1: work");
  commit(root, { "slices/s1/SPEC.md": spec("s1", "done") }, "s1: done");
  commit(root, { "slices/s2/SPEC.md": spec("s2", "in_progress") }, "s2: start");
  commit(root, { "packages/b/y.ts": "y\n", "README.md": "b\n" }, "s2: work");
  return { root, base };
}

function filesFor(id: string, root: string, base: string) {
  const r = Bun.spawnSync(
    ["bash", "-uc", `set -o pipefail; . "${lib}"; SLICE_ID="$2"; slice_files "$1"; echo "rc=$?"; printf '%s\\n' "$SLICE_FILES"`, "x", base, id],
    { cwd: root, env, stdout: "pipe", stderr: "pipe" },
  );
  const out = r.stdout.toString().trim().split("\n");
  const i = out.findIndex((l) => l.startsWith("rc="));
  return { rc: out[i], files: out.slice(i + 1).filter(Boolean) };
}

test("SCOPE: a done slice is checked only up to the commit that set status: done (later slices' files are not its)", () => {
  const { root, base } = stackedRepo();
  writeFileSync(join(root, "packages", "b", "z.ts"), "uncommitted work of the next slice\n");
  expect(filesFor("s1", root, base)).toEqual({ rc: "rc=0", files: ["packages/a/x.ts", "slices/s1/SPEC.md"] });
});

test("SCOPE: a file the done slice itself changed outside its scope is still reported", () => {
  const { root, base } = stackedRepo({ s1Extra: { "apps/web/oops.ts": "o\n" } });
  expect(filesFor("s1", root, base).files).toEqual(["apps/web/oops.ts", "packages/a/x.ts", "slices/s1/SPEC.md"]);
});

test("SCOPE: an in_progress slice still counts every change since BASE, committed or not", () => {
  const { root, base } = stackedRepo();
  writeFileSync(join(root, "packages", "b", "z.ts"), "z\n");
  expect(filesFor("s2", root, base).files).toEqual([
    "README.md", "packages/a/x.ts", "packages/b/y.ts", "packages/b/z.ts", "slices/s1/SPEC.md", "slices/s2/SPEC.md",
  ]);
});

test("SCOPE: status: done not yet committed falls back to everything since BASE", () => {
  const { root, base } = stackedRepo();
  writeFileSync(join(root, "slices", "s2", "SPEC.md"), spec("s2", "done"));
  expect(filesFor("s2", root, base).files).toContain("packages/b/y.ts");
  expect(filesFor("s2", root, base).files).toContain("slices/s2/SPEC.md");
});

// One squash commit lands several slices at once (a PR squash-merged to main): it sets s1 done and also carries
// s2's files and SPEC. s2's own verify.sh scope-checks that commit, so s2's in-scope files are not charged to s1.
const scopedSpec = (id: string, status: string, inScope: string, outOfScope = "[]") =>
  `---\nid: ${id}\nstatus: ${status}\npaths_in_scope: ${inScope}\npaths_out_of_scope: ${outOfScope}\n---\n`;
const s1Spec = (status: string) => scopedSpec("s1", status, "[packages/a/**, slices/s1/**]");
const s2Spec = (status: string) =>
  scopedSpec("s2", status, "[docs/**, STATUS.md, slices/s2/**]", "[docs/private/**]");

type SquashOpts = { squash?: Record<string, string>; s2Before?: string; s1Earlier?: Record<string, string> };
function squashRepo(opts: SquashOpts = {}) {
  const root = mkdtempSync(join(tmpdir(), "slice-changes-squash-"));
  dirs.push(root);
  git(root, "init", "-q", "-b", "main");
  const base = commit(root, { "README.md": "a\n", "slices/s1/SPEC.md": s1Spec("in_progress") }, "base");
  if (opts.s2Before) commit(root, { "slices/s2/SPEC.md": s2Spec(opts.s2Before) }, "s2 earlier");
  if (opts.s1Earlier) commit(root, opts.s1Earlier, "s1: earlier work");
  const upstream = git(root, "rev-parse", "HEAD");
  commit(root, {
    "slices/s1/SPEC.md": s1Spec("done"),
    "packages/a/x.ts": "x\n",
    "slices/s2/SPEC.md": s2Spec("in_progress"),
    "slices/s2/verify.sh": "v\n",
    "docs/guide.md": "g\n",
    "STATUS.md": "s\n",
    ...(opts.squash ?? {}),
  }, "squash: s1 done, s2 files");
  return { root, base, upstream };
}

function squashFiles(id: string, root: string, base: string, upstream?: string) {
  const r = Bun.spawnSync(
    ["bash", "-uc", `set -o pipefail; . "${lib}"; SLICE_ID="$2"; slice_files "$1"; echo "rc=$?"; printf '%s\\n' "$SLICE_FILES"`, "x", base, id],
    { cwd: root, env: upstream ? { ...env, SLICE_UPSTREAM: upstream } : env, stdout: "pipe", stderr: "pipe" },
  );
  const out = r.stdout.toString().trim().split("\n");
  const i = out.findIndex((l) => l.startsWith("rc="));
  return { log: out.slice(0, i).join("\n"), rc: out[i], files: out.slice(i + 1).filter(Boolean) };
}

const s1Own = ["packages/a/x.ts", "slices/s1/SPEC.md"];

test("SCOPE: a squash that sets a slice done does not charge it another landing slice's in-scope files", () => {
  const { root, base, upstream } = squashRepo();
  const ci = squashFiles("s1", root, base, upstream);
  expect({ rc: ci.rc, files: ci.files }).toEqual({ rc: "rc=0", files: s1Own });
  expect(ci.log).toContain("s2");
  expect(squashFiles("s1", root, base).files).toEqual(s1Own);
});

test("SCOPE: in a squash, a file the done slice changed outside every landing slice's scope is still reported", () => {
  const { root, base, upstream } = squashRepo({ squash: { "apps/web/oops.ts": "o\n" } });
  expect(squashFiles("s1", root, base, upstream).files).toEqual(["apps/web/oops.ts", ...s1Own]);
});

test("SCOPE: in a squash, a file in another slice's paths_out_of_scope is still charged to the done slice", () => {
  const { root, base, upstream } = squashRepo({ squash: { "docs/private/x.md": "p\n" } });
  expect(squashFiles("s1", root, base, upstream).files).toEqual(["docs/private/x.md", ...s1Own]);
});

test("SCOPE: in a squash, another slice that is only ready there does not take files from the done slice", () => {
  const { root, base, upstream } = squashRepo({ squash: { "slices/s2/SPEC.md": s2Spec("ready") } });
  expect(squashFiles("s1", root, base, upstream).files).toEqual([
    "STATUS.md", "docs/guide.md", ...s1Own, "slices/s2/SPEC.md", "slices/s2/verify.sh",
  ]);
});

test("SCOPE: in a squash, a slice already done before that commit does not take files from the done slice", () => {
  const touched = s2Spec("done") + "\nnote\n";
  const { root, base, upstream } = squashRepo({ s2Before: "done", squash: { "slices/s2/SPEC.md": touched } });
  expect(squashFiles("s1", root, base, upstream).files).toEqual([
    "STATUS.md", "docs/guide.md", ...s1Own, "slices/s2/SPEC.md", "slices/s2/verify.sh",
  ]);
});

test("SCOPE: a file the done slice changed in an earlier commit stays charged even if a landing slice owns it", () => {
  const { root, base } = squashRepo({ s1Earlier: { "docs/guide.md": "mine\n" } });
  expect(squashFiles("s1", root, base).files).toEqual(["docs/guide.md", ...s1Own]);
});

test("SCOPE: a slice landing in the same squash is still charged every file of that commit itself", () => {
  const { root, base, upstream } = squashRepo({ squash: { "apps/web/oops.ts": "o\n" } });
  expect(squashFiles("s2", root, base, upstream).files).toEqual([
    "STATUS.md", "apps/web/oops.ts", "docs/guide.md", "packages/a/x.ts", "slices/s1/SPEC.md", "slices/s2/SPEC.md",
    "slices/s2/verify.sh",
  ]);
});
