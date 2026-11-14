// The 473cafb hardening, re-stated for v2 (old loop-hardening.test.ts): a build left by a dead orchestrator is
// recoverable; no worker is left running when a build ends; a gate that stopped the first attempt before any try does
// not fan out; both checks need teeth; the cap is checked before anything is spent; stored records keep their shape.
import { describe, expect, test } from "bun:test";
import { ApprovalError, MemoryApprovals } from "../../src/approvals.ts";
import { buildConfig } from "../../src/config.ts";
import { OkBuildError, okBuild, runBuild } from "../../src/loop.ts";
import { FIX, harness, hashesOf, MEMBER, T0, TENANT, text, type Verdict } from "./setup.ts";

const ok = (h: ReturnType<typeof harness>) => okBuild(h.deps, { tenant_id: TENANT, member_id: MEMBER, fix_id: FIX, body: hashesOf(h.fix) });
const heldOutFailsFirst: Verdict = ({ work, shard }) => {
  const slug = text(work.has("slug.ts") ? { path: "", bytes: work.get("slug.ts")! } : undefined);
  if (slug === "") return { pass: false };
  return { pass: !(slug.includes("first") && shard === "held_out") };
};

describe("p45a hardening", () => {
  test("LOCK: a build with no progress for longer than the stale limit is ended infra_failed by the next OK, which then starts", async () => {
    const h = harness();
    const dead = await ok(h); // queued, its orchestrator never runs
    h.clock.now = T0 + h.deps.config.stale_after_ms + 1;
    const fresh = await ok(h);
    expect(fresh.build_id).not.toBe(dead.build_id);
    const old = (await h.store.get(TENANT, dead.build_id))!;
    expect(old.state).toBe("infra_failed");
    expect(old.stages.at(-1)!.note).toContain("no progress");
    await runBuild(h.deps, { tenant_id: TENANT, build_id: fresh.build_id, token: fresh.token });
    expect((await h.store.get(TENANT, fresh.build_id))!.state).toBe("ready");
  });

  test("LOCK: a build younger than the stale limit still refuses (409) and is left alone", async () => {
    const h = harness();
    const live = await ok(h);
    h.clock.now = T0 + h.deps.config.stale_after_ms - 60_000;
    const err = await ok(h).catch((e) => e);
    expect(err).toBeInstanceOf(OkBuildError);
    expect((err as OkBuildError).code).toBe("already_running");
    expect((await h.store.get(TENANT, live.build_id))!.state).toBe("queued");
  });

  test("LOCK: the stale limit covers a worker attempt at full wall time plus its verification, twice", () => {
    const c = buildConfig();
    expect(c.worker_wall_ms).toBe(12 * 60_000);
    expect(c.verify_wall_ms).toBe(5 * 60_000);
    expect(c.stale_after_ms).toBeGreaterThanOrEqual(2 * (c.worker_wall_ms + c.verify_wall_ms));
  });

  test("FANOUT: a worker whose attempt claim cannot be minted is recorded; no worker is left running when the build ends", async () => {
    const h = harness([{ files: { "slug.ts": "// good first\n" } }, { delayMs: 40 }, {}, {}], { verdict: heldOutFailsFirst, config: { fanout_workers: 3 } });
    // the third attempt claim is refused
    const real = h.approvals.mint.bind(h.approvals);
    let n = 0;
    h.approvals.mint = async (i, now) => {
      if (i.rule_id === "core.build.attempt" && ++n === 3) throw new ApprovalError("forbidden", "refused for the test");
      return real(i, now);
    };
    const { build_id } = await h.okAndRun();
    const b = (await h.store.get(TENANT, build_id))!;
    const attempts = await h.store.attempts(TENANT, build_id);
    expect(h.worker.live).toBe(0);
    expect(b.ended_at).not.toBeNull();
    expect(["ready", "failed"]).toContain(b.state);
    expect(attempts).toHaveLength(4);
    const refused = attempts.filter((a) => a.outcome === "error");
    expect(refused).toHaveLength(1);
    expect(refused[0]!.note.length).toBeGreaterThan(0);
    expect(h.provider.sandboxes.every((s) => s.destroyed)).toBe(true);
    expect(b.state).toBe("ready");
  });

  test("FANOUT: a fan-out worker that throws before claiming does not hold up the others", async () => {
    const h = harness([{ files: { "slug.ts": "// good first\n" } }, { throws: "setup failed" }, {}, {}], { verdict: heldOutFailsFirst, config: { fanout_workers: 3 } });
    const { build_id } = await h.okAndRun();
    const b = (await h.store.get(TENANT, build_id))!;
    const attempts = await h.store.attempts(TENANT, build_id);
    expect(attempts).toHaveLength(4);
    expect(attempts.find((a) => a.ordinal === 2)!.outcome).toBe("error");
    expect(b.state).toBe("ready");
  });

  test("FANOUT: a first attempt that ended before any try ran does not fan out", async () => {
    const h = harness([{}, {}], { config: { fanout_workers: 3 } });
    // the first attempt's sandbox cannot be given its files: zero tries
    const real = h.provider.putFiles.bind(h.provider);
    let first = true;
    h.provider.putFiles = async (s, m, f) => {
      if (first && h.provider.sandboxes.find((x) => x.id === s.id)!.spec.role === "worker") {
        first = false;
        throw new Error("disk full");
      }
      return real(s, m, f);
    };
    const { build_id } = await h.okAndRun();
    const attempts = await h.store.attempts(TENANT, build_id);
    expect(attempts).toHaveLength(1);
    expect(attempts[0]!.tries).toBe(0);
    expect(["failed", "infra_failed"]).toContain((await h.store.get(TENANT, build_id))!.state);
  });

  test("TEETH: a held-out check that passes on an empty workspace stops the build before any worker", async () => {
    const h = harness([{}], { verdict: ({ work, shard }) => ({ pass: work.size === 0 ? shard === "held_out" : true }) });
    const { build_id } = await h.okAndRun();
    const b = (await h.store.get(TENANT, build_id))!;
    expect(h.worker.turns).toHaveLength(0);
    expect(b.state).toBe("failed");
    expect(b.stages.at(-1)!.note).toContain("the held-out check passes on an empty workspace (no teeth)");
  });

  test("TEETH: checks with teeth are each run once on an empty workspace, then the build goes on", async () => {
    const h = harness();
    const { build_id } = await h.okAndRun();
    const empty = h.provider.verification().filter((s) => s.execs.length > 0).slice(0, 2);
    expect(empty).toHaveLength(2);
    for (const s of empty) expect(s.work.size).toBe(0);
    expect((await h.store.get(TENANT, build_id))!.state).toBe("ready");
  });

  test("TEETH: a check that writes into the workspace is refused", async () => {
    const h = harness([{}], { verdict: ({ work, shard }) => (work.size === 0 ? { pass: false, write: shard === "frozen" } : { pass: true }) });
    const { build_id } = await h.okAndRun();
    const b = (await h.store.get(TENANT, build_id))!;
    expect(h.worker.turns).toHaveLength(0);
    expect(b.state).toBe("failed");
    expect(b.stages.at(-1)!.note).toContain("a check wrote into the workspace");
  });

  test("BUDGET: a cap too small for one worker ends the build capped before any sandbox or worker (nothing is spent)", async () => {
    // cap $0.90: minus the $0.30 reserve leaves $0.60, under one $0.70 attempt
    const h = harness([{}], { config: { cap_usd4: 9_000 } });
    const { build_id } = await h.okAndRun({ cap_usd: 0.9 });
    const b = (await h.store.get(TENANT, build_id))!;
    expect(b.state).toBe("capped");
    expect(b.spent_usd4).toBe(0);
    expect(h.provider.sandboxes).toHaveLength(0);
    expect(h.worker.turns).toHaveLength(0);
    expect(b.stages.at(-1)!.note).toContain("budget");
  });

  test("READY: no stored build, attempt or stage carries a host path, an approval token or exception text", async () => {
    const tokens: string[] = [];
    const a = harness([{ files: { "slug.ts": "// good first\n" } }, { throws: "Error at /home/someone/secret/path.ts:12" }], { verdict: heldOutFailsFirst });
    const realMint = a.approvals.mint.bind(a.approvals);
    a.approvals.mint = async (i, now) => {
      const r = await realMint(i, now);
      tokens.push(r.token);
      return r;
    };
    const ra = await a.okAndRun();
    const b = harness();
    const rb = await b.okAndRun();
    for (const [h, id] of [[a, ra.build_id], [b, rb.build_id]] as const) {
      const stored = JSON.stringify({ build: await h.store.get(TENANT, id), attempts: await h.store.attempts(TENANT, id), entries: h.store.entries });
      expect(stored).not.toMatch(/\/(home|tmp|private|var)\//);
      expect(stored).not.toContain("someone");
      for (const t of tokens) expect(stored).not.toContain(t);
    }
    expect(tokens.length).toBeGreaterThan(1);
  });

  test("CAP: three parallel workers cannot together overshoot the build cap", async () => {
    // cap $2.00 holds two $0.70 attempts after the reserve: three asks at once, exactly two fit
    const h = harness([], { config: { cap_usd4: 20_000 } });
    const r = await okBuild(h.deps, { tenant_id: TENANT, member_id: MEMBER, fix_id: FIX, body: { ...hashesOf(h.fix), cap_usd: 2 } });
    const got = await Promise.all([1, 2, 3].map((n) => h.store.reserve({ tenant_id: TENANT, build_id: r.build_id, attempt_id: `a${n}`, call_id: `attempt:a${n}`, kind: "model", usd4: 7_000, ceiling_usd4: 17_000 }, T0)));
    expect(got.filter(Boolean)).toHaveLength(2);
  });

  test("GATE: the memory approvals adapter is the default only in tests; nothing reads a token from the build row", async () => {
    const h = harness();
    expect(h.approvals).toBeInstanceOf(MemoryApprovals);
    const r = await ok(h);
    const row = JSON.stringify(await h.store.get(TENANT, r.build_id));
    expect(row).not.toContain(r.token);
  });
});
