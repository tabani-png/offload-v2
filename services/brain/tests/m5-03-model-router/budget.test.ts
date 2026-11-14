import { describe, expect, test } from "bun:test";
import { InMemoryBudgetLedger } from "@offload/testkit/src/models/index.ts";
import { loadDefaultModelsConfig } from "../../src/models/config.ts";
import { route } from "../../src/models/router.ts";
import { call, harness, pricedConfig, TENANT, TEST_PRICES } from "./helpers.ts";

const LOCAL_ENV = { OFFLOAD_LOCAL_MODEL_URL: "http://127.0.0.1:11434" };

describe("m5-03 budgets", () => {
  test("BUDGET: a reservation above the run's remaining budget is refused and the provider is not called", async () => {
    const h = harness();
    // Worst case for haiku with max_tokens 1000 is at least 1000 × $10 / 1M = $0.01.
    const res = await route(call({ run_id: "r_small", run_budget_usd: 0.005, max_tokens: 1000 }), h.deps);
    expect(res.status).toBe("needs_you");
    if (res.status === "needs_you") expect(res.reason).toBe("run_budget_reached");
    expect(h.provider.requests).toHaveLength(0);
    expect(h.ledger.entries).toHaveLength(0);

    // Spend already in the run counts against what is left.
    const ok = await route(call({ call_id: "c_run_1", run_id: "r_big", run_budget_usd: 0.05, max_tokens: 1000 }), h.deps);
    expect(ok.status).toBe("ok");
    const spent = await h.ledger.spentThisRun("r_big");
    const res2 = await route(call({ call_id: "c_run_2", run_id: "r_big", run_budget_usd: spent + 0.005, max_tokens: 1000 }), h.deps);
    expect(res2.status).toBe("needs_you");
    expect(h.provider.requests).toHaveLength(1);

    // The per-call cap from models.json applies too.
    const cap = await route(call({ route: "classify", max_tokens: 100_000 }), h.deps);
    expect(cap.status).toBe("needs_you");
    if (cap.status === "needs_you") expect(cap.reason).toBe("call_budget_exceeded");
    expect(h.provider.requests).toHaveLength(1);
  });

  test("BUDGET: a route whose model has no configured price is refused", async () => {
    const config = loadDefaultModelsConfig({});
    expect(config.tiers.opus.usd_per_mtok_in).toBeNull();
    expect(config.tiers.sonnet.usd_per_mtok_out).toBeNull();
    expect(config.tiers.haiku.usd_per_mtok_cache_read).toBeNull();
    const h = harness({ config });
    for (const r of ["design", "draft", "classify"]) {
      const res = await route(call({ route: r }), h.deps);
      expect(res.status).toBe("needs_you");
      if (res.status === "needs_you") expect(res.reason).toBe("prices_not_configured");
    }
    expect(h.provider.requests).toHaveLength(0);
    expect(h.ledger.entries).toHaveLength(0);
  });

  test("BUDGET: at 80% of the monthly budget classify and caption go to the local tier when it is configured", async () => {
    const ledger = new InMemoryBudgetLedger({ monthlyBudgetUsd: 50 });
    ledger.seedMonthSpend(TENANT, 40);
    const h = harness({ ledger, config: pricedConfig(LOCAL_ENV) });
    for (const r of ["classify", "caption"]) {
      const res = await route(call({ call_id: `c_local_${r}`, route: r }), h.deps);
      expect(res.status).toBe("ok");
      if (res.status === "ok") {
        expect(res.tier).toBe("local");
        expect(res.usd).toBe(0);
      }
      expect(h.provider.requests.at(-1)!.tier).toBe("local");
    }
    // Other routes stay on their paid tier.
    const draft = await route(call({ call_id: "c_draft", route: "draft" }), h.deps);
    expect(draft.status).toBe("ok");
    expect(h.provider.requests.at(-1)!.tier).toBe("sonnet");

    // Below 80% classify stays on haiku.
    const low = new InMemoryBudgetLedger({ monthlyBudgetUsd: 50 });
    low.seedMonthSpend(TENANT, 39);
    const h2 = harness({ ledger: low, config: pricedConfig(LOCAL_ENV) });
    await route(call({ route: "classify" }), h2.deps);
    expect(h2.provider.requests[0]!.tier).toBe("haiku");

    // At 80% without a local tier configured, classify stays on haiku.
    const h3 = harness({ ledger, config: pricedConfig({}) });
    await route(call({ call_id: "c_nolocal", route: "classify" }), h3.deps);
    expect(h3.provider.requests[0]!.tier).toBe("haiku");
  });

  test("BUDGET: every call writes one ledger entry keyed by its call id and settles the reservation", async () => {
    const h = harness();
    const first = await route(call({ call_id: "c_once", scope: "design", scope_id: "opp_1" }), h.deps);
    expect(first.status).toBe("ok");
    expect(h.ledger.entries).toHaveLength(1);
    const e = h.ledger.entries[0]!;
    expect(e.idempotency_key).toBe("c_once");
    expect(e.scope).toBe("design");
    expect(e.scope_id).toBe("opp_1");
    expect(e.model).toBe("claude-haiku-5-5");
    expect(e.state).toBe("settled");
    const req = h.provider.requests[0]!;
    const inTok = h.provider.estimateInputTokens(req);
    // Settled with actual usage: input tokens × input price + 10 output tokens × output price.
    expect(e.usd).toBeCloseTo((inTok * TEST_PRICES.haiku.in + 10 * TEST_PRICES.haiku.out) / 1e6, 12);
    // Reserved at worst case: input tokens × input price + max_tokens × output price.
    expect(e.reserved_usd).toBeCloseTo((inTok * TEST_PRICES.haiku.in + 200 * TEST_PRICES.haiku.out) / 1e6, 12);
    expect(first.status === "ok" && first.usd).toBeCloseTo(e.usd, 12);
    expect(h.ledger.usage).toEqual([
      { tenant_id: TENANT, day: "2026-11-14", model: "claude-haiku-5-5", route: "classify", calls: 1, input_tokens: inTok, output_tokens: 10, usd: e.usd },
    ]);

    // A retry with the same call id writes once and does not call the model again.
    const retry = await route(call({ call_id: "c_once", scope: "design", scope_id: "opp_1" }), h.deps);
    expect(retry.status).toBe("needs_you");
    if (retry.status === "needs_you") expect(retry.reason).toBe("call_already_settled");
    expect(h.ledger.entries).toHaveLength(1);
    expect(h.provider.requests).toHaveLength(1);

    // Default scope is brain.
    await route(call({ call_id: "c_brain" }), h.deps);
    expect(h.ledger.entries[1]!.scope).toBe("brain");
  });

  test("BUDGET: an escalated call budgets each attempt", async () => {
    const h = harness({ provider: { script: { haiku: ["refusal"], sonnet: ["refusal"] } } });
    const res = await route(call({ call_id: "c_esc", run_id: "r_esc" }), h.deps);
    expect(res.status).toBe("ok");
    expect(h.ledger.entries.map((e) => [e.idempotency_key, e.model, e.state])).toEqual([
      ["c_esc", "claude-haiku-5-5", "settled"],
      ["c_esc:2", "claude-sonnet-5-5", "settled"],
      ["c_esc:3", "claude-opus-5-5", "settled"],
    ]);
    if (res.status === "ok") {
      expect(res.attempts.map((a) => a.tier)).toEqual(["haiku", "sonnet", "opus"]);
      expect(res.usd).toBeCloseTo(h.ledger.entries.reduce((s, e) => s + e.usd, 0), 12);
    }

    // When the next tier's worst case does not fit the run budget, the call stops before sending it.
    const h2 = harness({ provider: { script: { haiku: ["refusal"] } } });
    const tight = await route(call({ call_id: "c_tight", run_id: "r_tight", run_budget_usd: 0.003, max_tokens: 200 }), h2.deps);
    expect(tight.status).toBe("needs_you");
    if (tight.status === "needs_you") expect(tight.reason).toBe("run_budget_reached");
    expect(h2.provider.tiers()).toEqual(["haiku"]);
    expect(h2.ledger.entries).toHaveLength(1);
  });
});
