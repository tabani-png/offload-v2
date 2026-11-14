import { afterAll, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";

// scripts/lib/slice-changes.sh against a repo shaped like a GitHub pull_request checkout: HEAD is a merge commit
// whose first parent is main (which moved on after BASE) and whose second parent is the slice branch.
const lib = join(import.meta.dir, "..", "lib", "slice-changes.sh");
const dirs: string[] = [];
afterAll(() => dirs.forEach((d) => rmSync(d, { recursive: true, force: true })));

const env = {
  ...process.env,
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
