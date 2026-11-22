// The build workflow (old loop.test.ts, re-stated for v2): the user's OK mints an exact-hash approval; the build claims
// it first; frozen and held-out checks are read by hash; teeth gate; one test-first worker; check shards in parallel
// fresh verification sandboxes, any fail = FAIL; fan-out on FAIL only; winner order; build cap.
import { describe, expect, test } from "bun:test";
import { buildConfig, ConfigError } from "../../src/config.ts";
import { OkBuildError, okBuild, pickWinner, runBuild } from "../../src/loop.ts";
import { TDD_INSTRUCTIONS } from "../../src/attempt.ts";
import { checkSet, FIX, harness, hashesOf, HELDOUT_CONTENT, MEMBER, T0, TENANT, text, type Verdict } from "./setup.ts";

const view = async (h: ReturnType<typeof harness>, id: string) => ({ build: (await h.store.get(TENANT, id))!, attempts: await h.store.attempts(TENANT, id) });
/** Held-out fails for the first attempt's artifact (marked "first"), everything else passes. */
const heldOutFailsFirst: Verdict = ({ work, shard }) => {
  const slug = text(work.has("slug.ts") ? { path: "slug.ts", bytes: work.get("slug.ts")! } : undefined);
  if (slug === "") return { pass: false };
  return { pass: !(slug.includes("first") && shard === "held_out") };
};

describe("p45a OK, build", () => {
  test("GATE: the build claims the user's approval as its first step; without that claim no sandbox, worker or model call runs", async () => {
    const h = harness();
    const r = await okBuild(h.deps, { tenant_id: TENANT, member_id: MEMBER, fix_id: FIX, body: hashesOf(h.fix) });
    const b0 = (await h.store.get(TENANT, r.build_id))!;
    expect(b0.state).toBe("queued");
    const appr = (await h.approvals.get(TENANT, b0.approval_id!))!;
    expect(appr).toMatchObject({ kind: "build", subject_id: r.build_id, approver_kind: "person", approver_member_id: MEMBER, claimed_at: null });
    expect(appr.bound_hashes).toEqual({ ...hashesOf(h.fix), cap_usd: "4.0000" });
    // a wrong token: the claim fails, the build fails, nothing ran
    await runBuild(h.deps, { tenant_id: TENANT, build_id: r.build_id, token: "x".repeat(43) });
    const b1 = (await h.store.get(TENANT, r.build_id))!;
    expect(b1.state).toBe("failed");
    expect(h.provider.sandboxes).toHaveLength(0);
    expect(h.worker.turns).toHaveLength(0);
    // the right token, once
    const h2 = harness();
    const { build_id } = await h2.okAndRun();
    const b2 = (await h2.store.get(TENANT, build_id))!;
    expect((await h2.approvals.get(TENANT, b2.approval_id!))!.claimed_at).not.toBeNull();
    expect(b2.state).toBe("ready");
  });

  test("CHECKS: the frozen check and the held-out check are read by hash before the first worker; a stored check whose bytes changed ends the build tampered", async () => {
    const h = harness();
    const r = await okBuild(h.deps, { tenant_id: TENANT, member_id: MEMBER, fix_id: FIX, body: hashesOf(h.fix) });
    h.fixes.fixes.get(`${TENANT}/${FIX}`)!.held_out = { ...checkSet("held_out", HELDOUT_CONTENT), content: HELDOUT_CONTENT + "// edited\n" };
    await runBuild(h.deps, { tenant_id: TENANT, build_id: r.build_id, token: r.token });
    const { build } = await view(h, r.build_id);
    expect(build.state).toBe("tampered");
    expect(h.provider.sandboxes).toHaveLength(0);
    expect(h.worker.turns).toHaveLength(0);
  });

  test("CHECKS: the held-out check never reaches a builder: not in its files, prompt or feedback", async () => {
    const h = harness([{ files: { "slug.ts": "// good first\n", "routine.json": "{}" } }, {}], { verdict: heldOutFailsFirst, config: { fanout_workers: 1 } });
    await h.okAndRun();
    expect(h.provider.workers().length).toBe(2);
    for (const w of h.provider.workers()) {
      const all = [...w.check.values(), ...w.work.values()].map((b) => new TextDecoder().decode(b)).join("\n");
      expect(all).not.toContain("SECRET-HELDOUT-MARKER");
      expect(all).not.toContain(h.fix.held_out.hash);
    }
    for (const t of h.worker.turns) {
      expect(t.prompt).not.toContain("SECRET-HELDOUT-MARKER");
      expect(t.prompt).not.toContain(h.fix.held_out.hash);
      expect(t.feedback ?? "").not.toContain("SECRET-HELDOUT-MARKER");
    }
  });

  test("DEFAULT1: one worker by default; with both shards passing the build is ready", async () => {
    const h = harness();
    const { build_id } = await h.okAndRun();
    const { build, attempts } = await view(h, build_id);
    expect(h.provider.workers()).toHaveLength(1);
    expect(attempts).toHaveLength(1);
    expect(build.state).toBe("ready");
    expect(attempts[0]!.check_groups).toEqual([{ name: "frozen", passed: 1, failed: 0 }, { name: "held_out", passed: 1, failed: 0 }]);
    expect(attempts[0]).toMatchObject({ frozen_pass: true, held_out_pass: true, outcome: "pass", ordinal: 1 });
    // the shard proofs are kept (DATA_MODEL worker_attempts.proof), never their one-time nonce
    expect(attempts[0]!.proof).toEqual({ frozen: { status: "pass", exit: 0, tests: 1, completed: true, swept: false, split: false }, held_out: { status: "pass", exit: 0, tests: 1, completed: true, swept: false, split: false } });
    expect(JSON.stringify(attempts[0])).not.toContain("nonce");
    expect(attempts[0]!.wall_seconds).toBe(0);
    expect(build.winner_attempt_id).toBe(attempts[0]!.id);
  });

  test("SHARDS: the shards run in parallel, one fresh sandbox per shard, against the attempt's artifact", async () => {
    const h = harness();
    await h.okAndRun();
    // teeth (2 shards on an empty workspace) + verification (2 shards)
    const v = h.provider.verification();
    expect(v).toHaveLength(4);
    expect(new Set(v.map((x) => x.id)).size).toBe(4);
    expect(h.provider.maxLiveVerification).toBe(2);
    const verify = v.slice(2);
    expect(verify.map((x) => (text({ path: "", bytes: x.check.get("accept.test.ts")! }).includes("HELDOUT") ? "held_out" : "frozen")).sort()).toEqual(["frozen", "held_out"]);
    for (const x of verify) expect(text({ path: "", bytes: x.work.get("slug.ts")! })).toContain("good");
    expect(v.every((x) => x.destroyed)).toBe(true);
  });

  test("SHARDS: any shard failing makes that attempt fail, and fans out to 3 parallel workers (fanout_workers 3)", async () => {
    const h = harness([{ files: { "slug.ts": "// good first\n" } }, { spent_usd: 0.3, delayMs: 20 }, { spent_usd: 0.2, delayMs: 20 }, { spent_usd: 0.25, delayMs: 20 }], { verdict: heldOutFailsFirst, config: { fanout_workers: 3 } });
    const { build_id } = await h.okAndRun();
    const { build, attempts } = await view(h, build_id);
    expect(attempts[0]).toMatchObject({ ordinal: 1, outcome: "fail", frozen_pass: true, held_out_pass: false });
    expect(attempts).toHaveLength(4);
    expect(h.worker.maxLive).toBe(3);
    expect(build.state).toBe("ready");
    expect(attempts.find((a) => a.id === build.winner_attempt_id)!.spent_usd4).toBe(2000);
  });

  test("FANOUT: default fanout_workers is 1 (M2); config refuses more than 3", async () => {
    expect(buildConfig().fanout_workers).toBe(1);
    expect(() => buildConfig({ fanout_workers: 4 })).toThrow(ConfigError);
    expect(() => buildConfig({ fanout_workers: 0 })).toThrow(ConfigError);
    const h = harness([{ files: { "slug.ts": "// good first\n" } }, {}], { verdict: heldOutFailsFirst });
    const { build_id } = await h.okAndRun();
    const { build, attempts } = await view(h, build_id);
    expect(attempts).toHaveLength(2);
    expect(build.fanout_workers).toBe(1);
    expect(build.state).toBe("ready");
  });

  test("FANOUT: winner order is all shards passing, then cost, then smaller artifact", async () => {
    // attempt 1 fails; 2 passes at $0.10 with a big artifact; 3 passes at $0.10 small; 4 is cheapest but fails held-out
    const h = harness(
      [
        { files: { "slug.ts": "// good first\n" } },
        { spent_usd: 0.1, files: { "slug.ts": "// good\n" + "x".repeat(500) } },
        { spent_usd: 0.1, files: { "slug.ts": "// good\n" } },
        { spent_usd: 0.05, files: { "slug.ts": "// good first cheap\n" } },
      ],
      { verdict: heldOutFailsFirst, config: { fanout_workers: 3 } },
    );
    const { build_id } = await h.okAndRun();
    const { build, attempts } = await view(h, build_id);
    const win = attempts.find((a) => a.id === build.winner_attempt_id)!;
    expect(win.ordinal).toBe(3);
    expect(win.artifact_bytes).toBeLessThan(attempts.find((a) => a.ordinal === 2)!.artifact_bytes);
  });

  test("FANOUT: among passing attempts the cheaper one wins even when its artifact is larger", async () => {
    const h = harness(
      [
        { files: { "slug.ts": "// good first\n" } },
        { spent_usd: 0.2, files: { "slug.ts": "// good\n" } },
        { spent_usd: 0.1, files: { "slug.ts": "// good\n" + "x".repeat(800) } },
      ],
      { verdict: heldOutFailsFirst, config: { fanout_workers: 2 } },
    );
    const { build_id } = await h.okAndRun();
    const { build, attempts } = await view(h, build_id);
    const win = attempts.find((a) => a.id === build.winner_attempt_id)!;
    expect(win.ordinal).toBe(3);
    expect(win.artifact_bytes).toBeGreaterThan(attempts.find((a) => a.ordinal === 2)!.artifact_bytes);
    const row = (o: number, spent: number, bytes: number) => ({ ...attempts[0]!, id: `a${o}`, ordinal: o, outcome: "pass" as const, frozen_pass: true, held_out_pass: true, spent_usd4: spent, artifact_bytes: bytes });
    expect(pickWinner([row(2, 2000, 10), row(3, 1000, 900), { ...row(4, 500, 1), held_out_pass: false, outcome: "fail" as const }])!.ordinal).toBe(3);
    expect(pickWinner([row(2, 1000, 10), row(3, 1000, 900)])!.ordinal).toBe(2);
  });

  test("FANOUT: a worker fail (not just a shard) fans out too; every worker gets its own approval claim", async () => {
    const bad = { "slug.ts": "// bad\n" };
    const h = harness([{ perTry: [bad, { "slug.ts": "// still bad\n" }] }, {}, {}, {}], { config: { fanout_workers: 3 } });
    const { build_id } = await h.okAndRun();
    const { build, attempts } = await view(h, build_id);
    expect(attempts).toHaveLength(4);
    expect(build.state).toBe("ready");
    const claims = [...h.approvals.rows.values()].filter((a) => a.rule_id === "core.build.attempt");
    expect(claims).toHaveLength(4);
    expect(new Set(claims.map((c) => c.subject_id))).toEqual(new Set(attempts.map((a) => a.id)));
    expect(claims.every((c) => c.claimed_at !== null && c.parent_approval_id === build.approval_id)).toBe(true);
  });

  test("FANOUT: when every worker fails the build fails, with the reasons in plain words", async () => {
    const h = harness([{ files: { "slug.ts": "// good first\n" } }], { verdict: heldOutFailsFirst, config: { fanout_workers: 3 } });
    const { build_id } = await h.okAndRun();
    const { build, attempts } = await view(h, build_id);
    expect(attempts).toHaveLength(4);
    expect(build.state).toBe("failed");
    expect(build.winner_attempt_id).toBeNull();
    const note = build.stages.at(-1)!.note!;
    expect(note).toContain("No build passed every check");
    expect(note).toContain("held-out check");
    expect(note).not.toContain("SECRET-HELDOUT-MARKER");
  });

  test("FANOUT: fan-out workers see the first attempt's frozen check output, and only that the held-out check failed", async () => {
    const out: Verdict = ({ work, shard }) => {
      const slug = text(work.has("slug.ts") ? { path: "", bytes: work.get("slug.ts")! } : undefined);
      if (slug === "") return { pass: false };
      if (slug.includes("first")) return shard === "frozen" ? { pass: false, output: "FROZEN-OUTPUT expected a-b got a--b" } : { pass: false, output: "HELDOUT-OUTPUT boundary SECRET-HELDOUT-MARKER" };
      return { pass: true };
    };
    const h = harness([{ files: { "slug.ts": "// good first\n" } }, {}], { verdict: out });
    await h.okAndRun();
    const fan = h.worker.turns.filter((t) => t.ordinal === 2);
    expect(fan[0]!.feedback).toContain("FROZEN-OUTPUT");
    expect(fan[0]!.feedback).toContain("The held-out check also failed");
    expect(fan[0]!.feedback).not.toContain("HELDOUT-OUTPUT");
    expect(fan[0]!.feedback).not.toContain("SECRET-HELDOUT-MARKER");
  });

  test("TEETH: a check with no teeth stops the build before any worker (no fan-out)", async () => {
    const h = harness([{}], { verdict: ({ work, shard }) => ({ pass: work.size === 0 ? shard === "frozen" : true }), config: { fanout_workers: 3 } });
    const { build_id } = await h.okAndRun();
    const { build, attempts } = await view(h, build_id);
    expect(attempts).toHaveLength(0);
    expect(h.provider.workers()).toHaveLength(0);
    expect(build.state).toBe("failed");
    expect(build.stages.at(-1)!.note).toContain("the frozen check passes on an empty workspace (no teeth)");
  });

  test("BUDGET: $4.00 per build: attempt caps plus the $0.30 checks reserve never exceed it; each attempt cap is $0.70", async () => {
    const c = buildConfig();
    expect([c.cap_usd4, c.checks_reserve_usd4, c.attempt_cap_usd4]).toEqual([40_000, 3_000, 7_000]);
    const h = harness([{ perTry: [{ "slug.ts": "// bad\n" }, { "slug.ts": "// bad 2\n" }], spent_usd: 0.7 }], { config: { fanout_workers: 3 } });
    const { build_id } = await h.okAndRun();
    const caps = [...new Set(h.worker.turns.map((t) => `${t.ordinal}:${t.cap_usd4}`))].map((s) => Number(s.split(":")[1]));
    expect(caps).toEqual([7000, 7000, 7000, 7000]);
    expect(caps.reduce((a, b) => a + b, 0) + c.checks_reserve_usd4).toBeLessThanOrEqual(c.cap_usd4);
    const { build } = await view(h, build_id);
    expect(build.spent_usd4).toBeLessThanOrEqual(build.cap_usd4);
    expect(build.cap_usd4).toBe(40_000);
  });

  test("BUDGET: a smaller cap fans out to fewer workers rather than starving each", async () => {
    // cap $2.00: reserve 0.30 leaves 1.70 = two attempts of 0.70 (first + one fan-out), never four thinner ones
    const h = harness([{ perTry: [{ "slug.ts": "// bad\n" }, { "slug.ts": "// bad 2\n" }], spent_usd: 0.5 }], { config: { fanout_workers: 3, cap_usd4: 20_000 } });
    await h.okAndRun({ cap_usd: 2 });
    const ordinals = new Set(h.worker.turns.map((t) => t.ordinal));
    expect(ordinals.size).toBe(2);
    for (const t of h.worker.turns) expect(t.cap_usd4).toBe(7000);
  });

  test("BUDGET: when the cap leaves no room for a fan-out worker after a failed first worker, the build ends capped, not failed", async () => {
    // cap $1.60: minus the $0.30 reserve leaves $1.30; the first worker spends its $0.70, no second $0.70 fits
    const h = harness([{ perTry: [{ "slug.ts": "// bad\n" }, { "slug.ts": "// bad 2\n" }], spent_usd: 0.35 }], { config: { cap_usd4: 16_000, fanout_workers: 3 } });
    const { build_id } = await h.okAndRun({ cap_usd: 1.6 });
    const { build, attempts } = await view(h, build_id);
    expect(attempts).toHaveLength(1);
    expect(build.state).toBe("capped");
    expect(build.stages.at(-1)!.note).toContain("build cap");
  });

  test("TDD: workers get the test-first, verify-before-done instructions (obra/superpowers), with stall stop and teeth gate on", async () => {
    const h = harness();
    await h.okAndRun();
    const t = h.worker.turns[0]!;
    expect(t.prompt).toContain(TDD_INSTRUCTIONS);
    expect(TDD_INSTRUCTIONS).toMatch(/failing test first/i);
    expect(TDD_INSTRUCTIONS).toMatch(/run the acceptance check/i);
    expect(h.deps.config.stop_on_stall).toBe(true);
    expect(h.provider.verification().length).toBeGreaterThanOrEqual(2);
  });

  test("STEPS: stages go teeth gate, worker, verification, winner, in plain words; nothing says dry run", async () => {
    const h = harness();
    const { build_id } = await h.okAndRun();
    const { build } = await view(h, build_id);
    expect(build.stages.map((s) => s.name)).toEqual(["teeth_gate", "worker", "verification", "winner"]);
    expect(build.stages.every((s) => s.state === "done" && s.ended_at !== null)).toBe(true);
    const all = JSON.stringify({ build, attempts: await h.store.attempts(TENANT, build_id) }).toLowerCase();
    expect(all).not.toMatch(/dry[ _-]?run|preview run/);
  });

  test("READY: the build lists the artifact files and their hash; deploy is its own approval", async () => {
    const h = harness([{ files: { "slug.ts": "// good\n", "routine.json": '{"name":"slugify"}\n', "README.md": "hi\n" } }]);
    const { build_id } = await h.okAndRun();
    const { build, attempts } = await view(h, build_id);
    expect(build.state).toBe("ready");
    expect(build.artifact_sha256).toMatch(/^[0-9a-f]{64}$/);
    expect(build.artifact_sha256).toBe(attempts[0]!.artifact_sha256);
    expect(attempts[0]!.artifact_files).toEqual(["README.md", "routine.json", "slug.ts"]);
    expect(build.receipt_hash).toMatch(/^[0-9a-f]{64}$/);
    expect(build.definition_hash).toMatch(/^[0-9a-f]{64}$/);
    expect(build.deployed_at).toBeNull();
    expect([...h.approvals.rows.values()].filter((a) => a.kind === "deploy")).toHaveLength(0);
  });

  test("LOCK: a second OK for the same brief while one runs gets already_running; the lock is released after the build ends", async () => {
    const h = harness([{ delayMs: 30 }]);
    const r = await okBuild(h.deps, { tenant_id: TENANT, member_id: MEMBER, fix_id: FIX, body: hashesOf(h.fix) });
    const running = runBuild(h.deps, { tenant_id: TENANT, build_id: r.build_id, token: r.token });
    const err = await okBuild(h.deps, { tenant_id: TENANT, member_id: MEMBER, fix_id: FIX, body: hashesOf(h.fix) }).catch((e) => e);
    expect(err).toBeInstanceOf(OkBuildError);
    expect((err as OkBuildError).code).toBe("already_running");
    await running;
    // a new build of the same brief needs a new held-out check (ADR 0029); with one, the lock is free
    const fresh = checkSet("held_out", HELDOUT_CONTENT.replace("edges", "edges two"));
    h.fixes.fixes.get(`${TENANT}/${FIX}`)!.held_out = fresh;
    const again = await okBuild(h.deps, { tenant_id: TENANT, member_id: MEMBER, fix_id: FIX, body: { ...hashesOf(h.fix), held_out_hash: fresh.hash } });
    expect(again.build_id).not.toBe(r.build_id);
  });

  test("ERROR: a worker that throws before claiming is recorded; the build still ends and frees its lock", async () => {
    const h = harness([{ throws: "agent crashed" }]);
    const { build_id } = await h.okAndRun();
    const { build, attempts } = await view(h, build_id);
    expect(["failed", "infra_failed"]).toContain(build.state);
    expect(build.ended_at).not.toBeNull();
    expect(attempts[0]!.outcome).toBe("error");
    expect(attempts[0]!.note).not.toContain("agent crashed");
    expect(h.provider.sandboxes.every((s) => s.destroyed)).toBe(true);
  });

  test("VERDICT: a pass printed inside the worker sandbox does not count; only the fresh verification sandbox decides", async () => {
    // the worker sandbox's own check run says PASS (the agent could print that); every fresh verification sandbox fails
    const h = harness([{ files: { "slug.ts": "// bad but loud\n" } }], { verdict: ({ role, work }) => ({ pass: role === "worker" && work.size > 0 }), config: { fanout_workers: 1 } });
    const { build_id } = await h.okAndRun();
    const { build, attempts } = await view(h, build_id);
    expect(attempts.every((a) => a.outcome === "fail" && a.frozen_pass === false)).toBe(true);
    expect(build.state).toBe("failed");
  });

  test("INFRA: a sandbox provider outage ends infra_failed, bills nothing to the cap and releases the approval once", async () => {
    const h = harness();
    const { SandboxInfraError } = await import("../../src/sandbox/provider.ts");
    h.provider.createError = new SandboxInfraError("provider down");
    const { build_id } = await h.okAndRun();
    const { build } = await view(h, build_id);
    expect(build.state).toBe("infra_failed");
    expect(build.spent_usd4).toBe(0);
    expect(h.store.entries.filter((e) => e.scope === "build")).toHaveLength(0);
    const appr = (await h.approvals.get(TENANT, build.approval_id!))!;
    expect(appr.released_at).not.toBeNull();
    expect(h.worker.turns).toHaveLength(0);
  });
});

describe("p45a infra failures after spend (ADR 0031)", () => {
  /** Verification sandboxes fail with a provider outage from the `from`-th one on (teeth uses the first two). */
  async function outageFrom(h: ReturnType<typeof harness>, from: number) {
    const { SandboxInfraError } = await import("../../src/sandbox/provider.ts");
    const real = h.provider.create.bind(h.provider);
    let n = 0;
    h.provider.create = async (spec) => {
      if (spec.role === "verification" && ++n >= from) throw new SandboxInfraError("provider down");
      return real(spec);
    };
  }

  test("INFRA: an outage at verification after a worker spent ends infra_failed, bills that spend as infra and starts no other worker", async () => {
    const h = harness([{ spent_usd: 0.5 }], { config: { fanout_workers: 3 } });
    await outageFrom(h, 3);
    const { build_id } = await h.okAndRun();
    const b = (await h.store.get(TENANT, build_id))!;
    expect(b.state).toBe("infra_failed");
    expect(b.spent_usd4).toBe(0);
    expect(h.store.entries.filter((e) => e.scope === "build" && e.usd4 > 0)).toHaveLength(0);
    expect(h.store.entries.filter((e) => e.scope === "infra").map((e) => e.usd4)).toEqual([5_000]);
    expect(new Set(h.worker.turns.map((t) => t.ordinal))).toEqual(new Set([1]));
    expect(b.stages.at(-1)!.note).toContain("Offload's side failed");
    expect(b.stages.at(-1)!.note).not.toContain("No build passed");
    // model money was spent: the approval is not released (a retry needs a new OK, ADR 0031)
    expect((await h.approvals.get(TENANT, b.approval_id!))!.released_at).toBeNull();
    const att = await h.store.attempts(TENANT, build_id);
    expect(att.map((a) => a.outcome)).toEqual(["error"]);
  });

  test("INFRA: an outage while a fan-out worker is verified ends infra_failed and bills that worker's spend as infra", async () => {
    const h = harness([{ files: { "slug.ts": "// good first\n" }, spent_usd: 0.3 }, { spent_usd: 0.4 }], { verdict: heldOutFailsFirst, config: { fanout_workers: 1 } });
    await outageFrom(h, 5); // teeth 2, worker 1's shards 2, then worker 2's shards
    const { build_id } = await h.okAndRun();
    const b = (await h.store.get(TENANT, build_id))!;
    expect(b.state).toBe("infra_failed");
    expect(h.store.entries.map((e) => [e.scope, e.usd4])).toEqual([["build", 3_000], ["infra", 4_000]]);
    expect(b.spent_usd4).toBe(3_000);
    expect(new Set(h.worker.turns.map((t) => t.ordinal))).toEqual(new Set([1, 2]));
  });
});

describe("p45a OK, build time", () => {
  test("GATE: an approval older than 24 h is approval_expired and the build never starts a worker", async () => {
    const h = harness();
    const r = await okBuild(h.deps, { tenant_id: TENANT, member_id: MEMBER, fix_id: FIX, body: hashesOf(h.fix) });
    h.clock.now = T0 + 24 * 3_600_000 + 1;
    await runBuild(h.deps, { tenant_id: TENANT, build_id: r.build_id, token: r.token });
    const b = (await h.store.get(TENANT, r.build_id))!;
    expect(b.state).toBe("failed");
    expect(b.stages.at(-1)!.note).toContain("expired");
    expect(h.provider.sandboxes).toHaveLength(0);
  });
});
