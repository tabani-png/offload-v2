import { describe, expect, test } from "bun:test";
import { route } from "../../src/models/router.ts";
import { call, harness, LABEL_SCHEMA } from "./helpers.ts";

describe("m5-03 router masking", () => {
  test("NAMES: the per-run name map never appears in logs, ledger entries or the result", async () => {
    // The fake model echoes the masked request back as its output, as a model drafting a reply would.
    const h = harness({ provider: { okContent: "Draft: thank <person:zzzz.1> for the invoice." } });
    const names = ["Priya", "Holmvik", "Tunde", "Okonkwo-Reyes", "Sam", "Okafor"];
    const res = await route(
      call({
        call_id: "c_names",
        run_id: "r_names",
        route: "draft",
        own_name: "Sam Okafor",
        system: "Write a short reply. Sign as Sam Okafor.",
        messages: [{ role: "user", content: "Priya Holmvik sent the invoice; Tunde Okonkwo-Reyes approved it." }],
      }),
      h.deps,
    );
    expect(res.status).toBe("ok");
    const sent = JSON.stringify(h.provider.requests);
    for (const n of names) expect(sent).not.toContain(n);
    expect(sent).toContain(".me>");

    const surfaces = {
      result: JSON.stringify(res),
      log: JSON.stringify(h.log.lines),
      ledger: JSON.stringify(h.ledger.entries) + JSON.stringify(h.ledger.reservations) + JSON.stringify(h.ledger.usage),
      audit: JSON.stringify(h.audit.events),
    };
    for (const [where, text] of Object.entries(surfaces)) {
      for (const n of names) expect({ where, found: text.includes(n) }).toEqual({ where, found: false });
    }
    expect(h.log.lines.length).toBeGreaterThan(0);
    // The router never unmasks a model's output: placeholders stay placeholders.
    if (res.status === "ok") expect(res.content).toBe("Draft: thank <person:zzzz.1> for the invoice.");

    // Structured output with a schema: same rule.
    const h2 = harness({ provider: { okContent: '{"label":"low"}' } });
    const r2 = await route(call({ route: "label", schema: { ...LABEL_SCHEMA }, messages: [{ role: "user", content: "Priya Holmvik asked." }] }), h2.deps);
    expect(JSON.stringify(r2)).not.toContain("Priya");
  });

  test("NAMES: a name in the schema is refused and a run's later own name is still masked", async () => {
    const h = harness();
    const schema = {
      type: "object",
      properties: { who: { type: "string", enum: ["Margaret Holloway", "Theodore Vance"], description: "Pick Margaret Holloway or Theodore Vance" } },
      required: ["who"],
      additionalProperties: false,
    };
    const r = await route(call({ route: "label", schema }), h.deps);
    expect(r.status === "refused" && r.reason).toBe("schema_holds_name");
    expect(h.provider.requests).toHaveLength(0);

    // A name the run already masked in a message cannot go out raw in the schema.
    const known = harness();
    const r2 = await route(
      call({
        route: "label",
        messages: [{ role: "user", content: "cc Zorvak Quellin on this" }],
        schema: { type: "object", properties: { who: { type: "string", enum: ["Zorvak Quellin", "other"] } }, required: ["who"], additionalProperties: false },
      }),
      known.deps,
    );
    expect(r2.status === "refused" && r2.reason).toBe("schema_holds_name");
    expect(known.provider.requests).toHaveLength(0);

    // One masker per run: the same name keeps one placeholder across calls, and once a call gives the member's own
    // name, later calls in the run mask it even when they leave own_name out.
    const { RunMaskers } = await import("../../src/models/router.ts");
    const h2 = harness();
    h2.deps.maskers = new RunMaskers();
    const text = "From Zorvak Quellin: ask Margaret Holloway to sort these.";
    await route(call({ call_id: "c_r0", run_id: "run1", messages: [{ role: "user", content: "Sort these." }] }), h2.deps);
    await route(call({ call_id: "c_r1", run_id: "run1", own_name: "Zorvak Quellin", messages: [{ role: "user", content: text }] }), h2.deps);
    await route(call({ call_id: "c_r2", run_id: "run1", messages: [{ role: "user", content: text }] }), h2.deps);
    await route(call({ call_id: "c_r3", run_id: "run1", own_name: "Zorvak Quellin", messages: [{ role: "user", content: text }] }), h2.deps);
    expect(JSON.stringify(h2.provider.requests)).not.toMatch(/Zorvak|Quellin|Margaret|Holloway/);
    const sent = h2.provider.requests.slice(1).map((r) => r.messages[0]!.content);
    expect(new Set(sent).size).toBe(1);
    expect(sent[0]).toMatch(/^From <person:[a-z]{4}\.me>: ask <person:[a-z]{4}\.1> to sort these\.$/);
    // A later call cannot loosen the run's own-name setting from mask to keep.
    await route(call({ call_id: "c_r4", run_id: "run1", own_name: "Zorvak Quellin", own_name_to_models: "keep", messages: [{ role: "user", content: text }] }), h2.deps);
    expect(h2.provider.requests.at(-1)!.messages[0]!.content).toBe(sent[0]!);
  });
});
