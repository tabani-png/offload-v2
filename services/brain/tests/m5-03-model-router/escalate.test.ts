import { describe, expect, test } from "bun:test";
import { modelStepTier, nextTier } from "../../src/models/escalation.ts";
import { route } from "../../src/models/router.ts";
import { call, harness, LABEL_SCHEMA } from "./helpers.ts";

describe("m5-03 escalation", () => {
  test("ESCALATE: a refusal from haiku retries on sonnet, then opus", async () => {
    const h = harness({ provider: { script: { haiku: ["refusal"], sonnet: ["refusal"] } } });
    const res = await route(call({ route: "classify" }), h.deps);
    expect(h.provider.tiers()).toEqual(["haiku", "sonnet", "opus"]);
    expect(res.status).toBe("ok");
    if (res.status === "ok") {
      expect(res.tier).toBe("opus");
      expect(res.model).toBe("claude-opus-5-5");
      expect(res.attempts.map((a) => a.outcome)).toEqual(["refusal", "refusal", "ok"]);
    }
    // Every attempt sends the same masked request.
    const [a, b, c] = h.provider.requests;
    expect(b!.messages).toEqual(a!.messages);
    expect(c!.system).toBe(a!.system);
    expect(h.provider.requests.map((r) => r.attempt)).toEqual([1, 2, 3]);
    expect(nextTier("haiku")).toBe("sonnet");
    expect(nextTier("sonnet")).toBe("opus");
    expect(nextTier("opus")).toBeNull();
  });

  test("ESCALATE: a cut-off reply or invalid structured output escalates one tier", async () => {
    const cut = harness({ provider: { script: { haiku: ["cut_off"] } } });
    const r1 = await route(call({ route: "classify", schema: { ...LABEL_SCHEMA } }), cut.deps);
    expect(cut.provider.tiers()).toEqual(["haiku", "sonnet"]);
    expect(r1.status === "ok" && r1.attempts.map((a) => a.outcome)).toEqual(["cut_off", "ok"]);

    const bad = harness({ provider: { script: { haiku: ["invalid_json"] } } });
    const r2 = await route(call({ route: "classify", schema: { ...LABEL_SCHEMA } }), bad.deps);
    expect(bad.provider.tiers()).toEqual(["haiku", "sonnet"]);
    expect(r2.status === "ok" && r2.output).toEqual({ label: "high" });

    // Valid JSON that does not match the schema (a label outside the enum) also escalates.
    const off = harness({ provider: { script: { haiku: [{ content: '{"label":"extreme"}' }] } } });
    const r3 = await route(call({ route: "classify", schema: { ...LABEL_SCHEMA } }), off.deps);
    expect(off.provider.tiers()).toEqual(["haiku", "sonnet"]);
    expect(r3.status === "ok" && r3.attempts[0]!.outcome).toBe("invalid_output");
  });

  test("ESCALATE: after opus fails the call ends needs_you and never goes down a tier", async () => {
    const top = harness({ provider: { script: { opus: ["refusal"] } } });
    const r1 = await route(call({ route: "design" }), top.deps);
    expect(r1.status).toBe("needs_you");
    if (r1.status === "needs_you") expect(r1.reason).toBe("escalation_exhausted");
    expect(top.provider.tiers()).toEqual(["opus"]);

    const all = harness({ provider: { fallback: "refusal" } });
    const r2 = await route(call({ route: "draft" }), all.deps);
    expect(r2.status).toBe("needs_you");
    if (r2.status === "needs_you") {
      expect(r2.reason).toBe("escalation_exhausted");
      expect(r2.attempts.map((a) => a.tier)).toEqual(["sonnet", "opus"]);
    }
    expect(all.provider.tiers()).toEqual(["sonnet", "opus"]);
    expect(all.ledger.entries.every((e) => e.state === "settled")).toBe(true);
  });

  test("ESCALATE: a model step drops to haiku after 5 clean runs and returns to sonnet on an edit", () => {
    expect(modelStepTier([])).toBe("sonnet");
    expect(modelStepTier(["clean", "clean", "clean", "clean"])).toBe("sonnet");
    expect(modelStepTier(["clean", "clean", "clean", "clean", "clean"])).toBe("haiku");
    expect(modelStepTier(["clean", "clean", "clean", "clean", "clean", "clean", "clean"])).toBe("haiku");
    expect(modelStepTier(["clean", "clean", "clean", "clean", "clean", "edit"])).toBe("sonnet");
    expect(modelStepTier(["clean", "clean", "clean", "clean", "clean", "failure"])).toBe("sonnet");
    expect(modelStepTier(["clean", "clean", "clean", "clean", "clean", "refusal"])).toBe("sonnet");
    // After a step back up, it needs 5 new clean runs.
    expect(modelStepTier(["clean", "clean", "clean", "clean", "clean", "edit", "clean", "clean", "clean", "clean"])).toBe("sonnet");
    expect(modelStepTier(["clean", "clean", "clean", "clean", "clean", "edit", "clean", "clean", "clean", "clean", "clean"])).toBe("haiku");
  });
});
