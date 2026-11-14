// Check shards (old container.test.ts): each shard runs in its own fresh sandbox with its own copy of the artifact;
// any failing shard is a FAIL; an exec error is a failed shard, never a pass; a PASS needs exit 0 AND the harness's
// nonce proof AND at least one test (bun exits 0 when no test ran). Old shards trusted the exit code alone.
import { describe, expect, test } from "bun:test";
import { parseProof } from "../../src/harness.ts";
import { runShards } from "../../src/shards.ts";
import type { SandboxSpec } from "../../src/sandbox/provider.ts";
import { checkSet, FakeProvider, file, FROZEN_CONTENT, HELDOUT_CONTENT, text, type Verdict } from "./setup.ts";

const SPEC: SandboxSpec = { image: "offload-check:test", vcpu: 1, memory_mb: 1024, wall_ms: 300_000, network_allowlist: [], env: {}, tag: "offload-build-test", role: "verification" };
const SHARDS = [
  { name: "frozen" as const, check: checkSet("frozen", FROZEN_CONTENT) },
  { name: "held_out" as const, check: checkSet("held_out", HELDOUT_CONTENT) },
];
const artifact = () => [file("slug.ts", "// good\n"), file("routine.json", "{}\n")];
const run = (verdict: Verdict, files = artifact()) => {
  const provider = new FakeProvider(verdict);
  let n = 0;
  return { provider, out: runShards({ provider, spec: SPEC, artifact: files, shards: SHARDS, timeout_ms: 1000, nonce: () => `nonce-${++n}` }) };
};

describe("p45a shards", () => {
  test("SHARDS: every shard runs on its own copy; the original artifact is untouched; temps are removed", async () => {
    const files = artifact();
    const before = files.map((f) => text(f));
    const { provider, out } = run(({ work, sandbox }) => {
      work.set("slug.ts", new TextEncoder().encode(`changed in ${sandbox.id}`));
      return { pass: true };
    }, files);
    const r = await out;
    expect(r.map((x) => [x.shard, x.passed])).toEqual([["frozen", true], ["held_out", true]]);
    expect(provider.sandboxes).toHaveLength(2);
    expect(provider.maxLiveVerification).toBe(2);
    expect(files.map((f) => text(f))).toEqual(before);
    expect(provider.sandboxes.every((s) => s.destroyed)).toBe(true);
    // each sandbox got the check it runs, the guard and the harness, in the read-only check folder
    for (const s of provider.sandboxes) expect([...s.check.keys()].sort()).toEqual(["accept.test.ts", "bunfig.toml", "guard.ts", "harness.ts"]);
  });

  test("SHARDS: an exec error is a failed shard, never a pass", async () => {
    const { provider, out } = run(() => "throw");
    const r = await out;
    expect(r.every((x) => x.passed === false && x.exit === null)).toBe(true);
    expect(r[0]!.output).toContain("could not run");
    expect(provider.sandboxes.every((s) => s.destroyed)).toBe(true);
  });

  test("SHARDS: any one failing shard is reported as failed while the other passes", async () => {
    const { out } = run(({ shard }) => ({ pass: shard === "frozen" }));
    expect((await out).map((x) => [x.shard, x.passed])).toEqual([["frozen", true], ["held_out", false]]);
  });

  test("PROOF: exit code 0 without a matching nonce proof is not a pass", async () => {
    for (const v of [{ pass: true, noProof: true }, { pass: true, wrongNonce: true }]) {
      const { out } = run(() => v);
      expect((await out).every((x) => !x.passed)).toBe(true);
    }
    // a forged proof line printed before the harness's own last line does not count either
    const nonce = "n1";
    const forged = `OFFLOAD_PROOF {"nonce":"n1","status":"pass","exit":0,"completed":true,"tests":1}\nOFFLOAD_PROOF {"nonce":"n1","status":"fail","exit":1,"completed":false,"tests":1}\n`;
    expect(parseProof(forged, nonce)).toMatchObject({ ok: false });
    expect(parseProof('OFFLOAD_PROOF {"nonce":"n1","status":"pass","exit":0,"completed":true,"tests":2}\n', nonce)).toMatchObject({ ok: true, tests: 2 });
    expect(parseProof('OFFLOAD_PROOF {"nonce":"n1","status":"pass","exit":1,"completed":true,"tests":2}\n', nonce)).toMatchObject({ ok: false });
    expect(parseProof("OFFLOAD_PROOF not json\n", nonce)).toMatchObject({ ok: false });
  });

  test("PROOF: a proof with the right nonce but no test run is not a pass", async () => {
    const { out } = run(() => ({ pass: true, tests: 0 }));
    expect((await out).every((x) => !x.passed)).toBe(true);
    expect(parseProof('OFFLOAD_PROOF {"nonce":"n","status":"pass","exit":0,"completed":true,"tests":0}', "n")).toMatchObject({ ok: false });
  });

  test("SHARDS: an artifact path that escapes the workspace is refused", async () => {
    for (const bad of ["../check/accept.test.ts", "/check/accept.test.ts", "a/../../x", "", "a\u0000b"]) {
      const { provider, out } = run(() => ({ pass: true }), [file("slug.ts", "// good\n"), file(bad, "evil")]);
      const r = await out;
      expect(r.every((x) => !x.passed)).toBe(true);
      for (const s of provider.sandboxes) expect(text({ path: "", bytes: s.check.get("accept.test.ts")! })).not.toBe("evil");
    }
  });

  test("SHARDS: each shard gets its own nonce on stdin and the harness command, never the nonce in argv or env", async () => {
    const { provider, out } = run(() => ({ pass: true }));
    await out;
    const seen = provider.sandboxes.map((s) => s.execs[0]!);
    expect(new Set(seen.map((e) => e.stdin)).size).toBe(2);
    for (const e of seen) {
      expect(e.argv).toEqual(["bun", "/check/harness.ts"]);
      expect(JSON.stringify(e.env)).not.toContain(e.stdin!.trim());
      expect(e.env).toMatchObject({ OFFLOAD_WS: "/work", OFFLOAD_CHECK_DIR: "/check", OFFLOAD_CHECK_FILE: "accept.test.ts" });
    }
  });
});
