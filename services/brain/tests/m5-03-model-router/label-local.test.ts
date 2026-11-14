import { describe, expect, test } from "bun:test";
import { InMemoryBudgetLedger } from "@offload/testkit/src/models/index.ts";
import { loadModelsConfig, ModelsConfigError } from "../../src/models/config.ts";
import { assertLabelSchema, LabelSchemaError, mapLabel, UnknownLabelError } from "../../src/models/labels.ts";
import { LocalModelUrlError, parseLocalModelUrl } from "../../src/models/local.ts";
import { route } from "../../src/models/router.ts";
import { call, harness, LABEL_SCHEMA, pricedConfig, pricedRaw, TENANT } from "./helpers.ts";

describe("m5-03 labels", () => {
  test("LABEL: a schema with a number field is refused before any call", async () => {
    const bad = [
      { type: "object", properties: { hours: { type: "number" } } },
      { type: "object", properties: { count: { type: "integer", enum: [1, 2, 3] } } },
      { type: "object", properties: { note: { type: "string" } } },
      { type: "object", properties: { items: { type: "array", items: { type: "number" } } } },
      { type: "object", properties: { nested: { type: "object", properties: { n: { type: ["string", "number"] } } } } },
      { type: "object", properties: { any: {} } },
    ];
    for (const s of bad) expect(() => assertLabelSchema(s)).toThrow(LabelSchemaError);

    // Labels, booleans and marked text fields are allowed.
    assertLabelSchema({ ...LABEL_SCHEMA });
    assertLabelSchema({
      type: "object",
      properties: {
        size: { type: "string", enum: ["s", "m", "l"] },
        repeats: { type: "boolean" },
        title: { type: "string", "x-offload-text": true },
        tags: { type: "array", items: { type: "string", enum: ["a", "b"] } },
      },
      required: ["size"],
      additionalProperties: false,
    });

    const h = harness();
    const res = await route(call({ route: "label", schema: bad[0]! }), h.deps);
    expect(res.status).toBe("refused");
    if (res.status === "refused") expect(res.reason).toBe("schema_not_label_only");
    expect(h.provider.requests).toHaveLength(0);
    expect(h.ledger.entries).toHaveLength(0);
  });

  test("LABEL: an unknown label throws in mapLabel", () => {
    const table = { low: 1, medium: 3, high: 8 } as const;
    expect(mapLabel(table, "medium")).toBe(3);
    expect(() => mapLabel(table, "extreme")).toThrow(UnknownLabelError);
    expect(() => mapLabel(table, "toString")).toThrow(UnknownLabelError);
    expect(() => mapLabel(table, "__proto__")).toThrow(UnknownLabelError);
  });
});

describe("m5-03 local tier", () => {
  test("LOCAL: refuses any host that is not loopback or a private network", () => {
    for (const ok of [
      "http://127.0.0.1:11434",
      "http://127.8.9.10:8000/v1",
      "http://localhost:11434",
      "http://[::1]:52415",
      "http://10.0.0.5:52415",
      "http://172.16.4.2",
      "http://172.31.255.255",
      "http://192.168.1.20:11434",
      "http://[fd12:3456:789a::1]:8080",
    ]) {
      expect(parseLocalModelUrl(ok).toString()).toBe(new URL(ok).toString());
    }
    for (const bad of [
      "http://203.0.113.5:11434",
      "https://api.example.com/v1",
      "http://8.8.8.8",
      "http://172.32.0.1",
      "http://11.0.0.1",
      "http://10.0.0.5.example.com",
      "http://localhost.example.com",
      "http://[2001:db8::1]",
      "http://0.0.0.0:11434",
      "http://user:pw@127.0.0.1:11434",
      "file:///etc/passwd",
      "not a url",
    ]) {
      expect(() => parseLocalModelUrl(bad)).toThrow(LocalModelUrlError);
    }
    // Refused at config load, too.
    expect(() => loadModelsConfig(pricedRaw(), { OFFLOAD_LOCAL_MODEL_URL: "http://203.0.113.5:11434" })).toThrow(ModelsConfigError);
    expect(pricedConfig({ OFFLOAD_LOCAL_MODEL_URL: "http://10.0.0.5:52415" }).local?.url).toBe("http://10.0.0.5:52415/");
  });

  test("LOCAL: the local tier is off when OFFLOAD_LOCAL_MODEL_URL is unset and never serves build", async () => {
    expect(pricedConfig({}).local).toBeUndefined();
    expect(pricedConfig({ OFFLOAD_LOCAL_MODEL_URL: "" }).local).toBeUndefined();

    // embed is a local-only route: with the local tier off it is refused with needs_you.
    const off = harness({ config: pricedConfig({}) });
    const e = await route(call({ route: "embed" }), off.deps);
    expect(e.status).toBe("needs_you");
    if (e.status === "needs_you") expect(e.reason).toBe("local_tier_off");
    expect(off.provider.requests).toHaveLength(0);

    // A config that lists build as a local route is refused at load.
    const raw = pricedRaw() as { local_routes: string[] };
    raw.local_routes = [...raw.local_routes, "build"];
    expect(() => loadModelsConfig(raw, { OFFLOAD_LOCAL_MODEL_URL: "http://127.0.0.1:11434" })).toThrow(ModelsConfigError);

    // At 80% with the local tier on, build still goes to sonnet.
    const ledger = new InMemoryBudgetLedger({ monthlyBudgetUsd: 50 });
    ledger.seedMonthSpend(TENANT, 45);
    const on = harness({ ledger, config: pricedConfig({ OFFLOAD_LOCAL_MODEL_URL: "http://127.0.0.1:11434" }) });
    const b = await route(call({ route: "build" }), on.deps);
    expect(b.status).toBe("ok");
    expect(on.provider.tiers()).toEqual(["sonnet"]);
    const emb = await route(call({ route: "embed" }), on.deps);
    expect(emb.status).toBe("ok");
    expect(on.provider.tiers()).toEqual(["sonnet", "local"]);
  });
});
