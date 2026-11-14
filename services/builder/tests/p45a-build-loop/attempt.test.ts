// One attempt (old runner-options.test.ts, which ran only on macOS with sandbox-exec; here against the port with a
// fake provider): the claim comes first, tries stop on a stalled artifact, a changed check file ends the build
// tampered, the worker sandbox holds no secret and no held-out check.
import { describe, expect, test } from "bun:test";
import { harness, TENANT, text } from "./setup.ts";

const SECRET_NAMES = /KEY|TOKEN|SECRET|PASSWORD|CREDENTIAL|AUTH|DATABASE_URL/i;

describe("p45a attempt", () => {
  test("STALL: the same failing artifact twice in a row stops the attempt as fail (stalled)", async () => {
    const h = harness([{ files: { "slug.ts": "// bad\n" } }], { config: { tries_per_attempt: 3, fanout_workers: 1 } });
    const { build_id } = await h.okAndRun();
    const attempts = await h.store.attempts(TENANT, build_id);
    expect(attempts[0]!.tries).toBe(2);
    expect(attempts[0]!.outcome).toBe("fail");
    expect(attempts[0]!.note).toContain("stalled");
    expect(h.worker.turns.filter((t) => t.ordinal === 1)).toHaveLength(2);
  });

  test("STALL: a changed failing artifact gets the next try, up to the tries per attempt", async () => {
    const h = harness([{ perTry: [{ "slug.ts": "// bad 1\n" }, { "slug.ts": "// bad 2\n" }, { "slug.ts": "// good 3\n" }] }], { config: { tries_per_attempt: 3 } });
    const { build_id } = await h.okAndRun();
    const attempts = await h.store.attempts(TENANT, build_id);
    expect(attempts[0]).toMatchObject({ tries: 3, outcome: "pass" });
    expect(h.worker.turns[1]!.feedback).toContain("1 fail");
  });

  test("BUDGET: a worker that reports more than its cap is settled at what it reported, and gets no further try", async () => {
    // The model egress proxy (m2-08) enforces the cap; the ledger records real money, never a clipped figure (ADR 0030).
    const h = harness([{ files: { "slug.ts": "// bad\n" }, spent_usd: 1 }], { config: { tries_per_attempt: 3, fanout_workers: 1 } });
    const { build_id } = await h.okAndRun();
    const attempts = await h.store.attempts(TENANT, build_id);
    expect(attempts[0]).toMatchObject({ ordinal: 1, outcome: "cap", tries: 1, spent_usd4: 10_000 });
    expect(h.store.entries.find((e) => e.idempotency_key === `attempt:${attempts[0]!.id}`)!.usd4).toBe(10_000);
    expect((await h.store.get(TENANT, build_id))!.spent_usd4).toBe(attempts.reduce((t, a) => t + a.spent_usd4, 0));
  });

  test("TAMPER: a check file changed during an attempt ends the build as tampered", async () => {
    const h = harness([{ tamper: true }], { config: { fanout_workers: 3 } });
    const { build_id } = await h.okAndRun();
    const b = (await h.store.get(TENANT, build_id))!;
    const attempts = await h.store.attempts(TENANT, build_id);
    expect(b.state).toBe("tampered");
    expect(attempts).toHaveLength(1);
    expect(attempts[0]!.outcome).toBe("tamper");
    expect(h.provider.sandboxes.every((s) => s.destroyed)).toBe(true);
  });

  test("TDD: the attempt claim happens once, before the first try, and the instructions are in the prompt", async () => {
    const h = harness();
    const order: string[] = [];
    const claim = h.approvals.claim.bind(h.approvals);
    h.approvals.claim = async (i, now) => {
      const row = await h.approvals.get(i.tenant_id, i.approval_id);
      if (row?.rule_id === "core.build.attempt") order.push("claim");
      return claim(i, now);
    };
    const turn = h.worker.turn.bind(h.worker);
    h.worker.turn = async (t) => {
      order.push("try");
      return turn(t);
    };
    await h.okAndRun();
    expect(order).toEqual(["claim", "try"]);
    expect(h.worker.turns[0]!.prompt).toContain("Work test-first");
  });

  test("SANDBOX: worker sandboxes get no credentials: only allowlisted env names, no network allowlist (ADR 0011)", async () => {
    const h = harness();
    await h.okAndRun();
    for (const s of h.provider.sandboxes) {
      expect(s.spec.network_allowlist).toEqual([]);
      for (const k of Object.keys(s.spec.env)) expect(k).not.toMatch(SECRET_NAMES);
      for (const e of s.execs) for (const k of Object.keys(e.env)) expect(k).not.toMatch(SECRET_NAMES);
      expect(s.spec.tag).toMatch(/^offload-build-/);
    }
    const w = h.provider.workers()[0]!;
    expect(w.spec).toMatchObject({ vcpu: 2, memory_mb: 4096, wall_ms: 12 * 60_000, role: "worker" });
    expect([...w.check.keys()].sort()).toEqual(["BUILD.md", "accept.test.ts", "bunfig.toml", "fixtures/instances/1.json", "guard.ts", "harness.ts"]);
    expect(text({ path: "", bytes: w.check.get("fixtures/instances/1.json")! })).toContain("tok_");
  });

  test("HELDOUT: the held-out check runs only in fresh verification sandboxes after the attempt, never in the worker sandbox", async () => {
    const h = harness();
    await h.okAndRun();
    for (const w of h.provider.workers()) expect(text({ path: "", bytes: w.check.get("accept.test.ts")! })).not.toContain("HELDOUT");
    const withHeld = h.provider.verification().filter((v) => text({ path: "", bytes: v.check.get("accept.test.ts")! }).includes("HELDOUT"));
    expect(withHeld).toHaveLength(2); // teeth run + verification run, each its own fresh sandbox
    expect(withHeld.every((v) => v.spec.role === "verification" && v.spec.wall_ms <= 5 * 60_000)).toBe(true);
  });
});
