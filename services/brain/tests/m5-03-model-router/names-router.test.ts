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
      ledger: JSON.stringify(h.ledger.entries) + JSON.stringify(h.ledger.usage),
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
});
