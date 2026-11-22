import { afterEach, beforeEach, expect, test } from "bun:test";
import { jcs, sha256Hex } from "@offload/contracts";
import { TemplateError, parseRoutine, planCommit, renderArgs } from "../../src/index.ts";
import { validRoutine } from "./fixtures.ts";

let realFetch: typeof globalThis.fetch;
let fetchCalls = 0;
beforeEach(() => {
  realFetch = globalThis.fetch;
  fetchCalls = 0;
  globalThis.fetch = (() => {
    fetchCalls++;
    throw new Error("I/O is not allowed in the routine SDK");
  }) as unknown as typeof globalThis.fetch;
});
afterEach(() => {
  globalThis.fetch = realFetch;
});

const scope = {
  steps: {
    payouts: { output: { data: [{ id: "tok_111111111111", amount: 1250 }] } },
    rows: {
      output: [
        { date: "2026-11-09", amount: 1250 },
        { date: "2026-11-10", amount: 990 },
      ],
    },
  },
};

test("ROUTINE: planCommit returns items with item_hash over JCS and performs no I/O", () => {
  const def = parseRoutine(validRoutine());
  const append = def.steps.find((s) => s.id === "append")!;
  const items = planCommit(append, scope);
  expect(items).toHaveLength(2);
  expect(items[0]).toEqual({
    item_key: items[0]!.item_key,
    item_hash: sha256Hex(jcs({ capability: "sheet.append", connection_ref: "finance_sheet", args: { sheet: "tok_aaaaaaaaaaaa", values: ["2026-11-09", 1250] } })),
    capability: "sheet.append",
    connection_ref: "finance_sheet",
    args: { sheet: "tok_aaaaaaaaaaaa", values: ["2026-11-09", 1250] }, // a whole-string reference keeps the number
  });
  for (const it of items) {
    expect(it.item_hash).toBe(sha256Hex(jcs({ capability: it.capability, connection_ref: it.connection_ref, args: it.args })));
    expect(it.item_key).toMatch(/^append\/[0-9a-f]{64}$/);
  }
  // item_key is stable for the same input item and differs between items
  expect(planCommit(append, scope).map((i) => i.item_key)).toEqual(items.map((i) => i.item_key));
  expect(items[0]!.item_key).not.toBe(items[1]!.item_key);
  // a commit step without foreach plans one item
  const notify = def.steps.find((s) => s.id === "notify")!;
  const one = planCommit(notify, { steps: { rows: { output: { count: 2 } } } });
  expect(one).toHaveLength(1);
  expect(one[0]!.args).toEqual({ shortcut: "tok_bbbbbbbbbbbb", text: "Appended 2 rows" });
  // only commit steps plan items; foreach over a non-list is refused
  expect(() => planCommit(def.steps[0]!, scope)).toThrow(TemplateError);
  expect(() => planCommit(append, { steps: { rows: { output: { not: "a list" } } } })).toThrow(TemplateError);
  expect(fetchCalls).toBe(0);
});

test("ROUTINE: renderArgs is pure and resolves only step outputs and item fields", () => {
  const args = { a: "{{ steps.payouts.output/data/0/amount }}", b: "id {{ steps.payouts.output/data/0/id }}!", c: ["{{ item.date }}"], d: { e: "{{ steps.rows.output }}" } };
  const before = structuredClone(scope);
  const out = renderArgs(args, { ...scope, item: { date: "2026-11-09" } });
  // a whole-string reference keeps the value's type; a reference inside text is joined as text
  expect(out).toEqual({ a: 1250, b: "id tok_111111111111!", c: ["2026-11-09"], d: { e: scope.steps.rows.output } });
  expect(scope).toEqual(before);
  expect(out["d"]).not.toBe(scope.steps.rows.output as unknown); // a copy, not the scope's object
  expect(() => renderArgs({ x: "{{ steps.nope.output }}" }, scope)).toThrow(TemplateError);
  expect(() => renderArgs({ x: "{{ steps.payouts.output/missing }}" }, scope)).toThrow(TemplateError);
  expect(() => renderArgs({ x: "{{ item.date }}" }, scope)).toThrow(TemplateError);
  expect(() => renderArgs({ x: "{{ 1 + 1 }}" }, scope)).toThrow(TemplateError);
  // an object cannot be joined into text
  expect(() => renderArgs({ x: "rows: {{ steps.rows.output }}" }, scope)).toThrow(TemplateError);
  // prototype keys are not reachable
  expect(() => renderArgs({ x: "{{ item.constructor }}" }, { ...scope, item: {} })).toThrow(TemplateError);
  expect(() => renderArgs({ x: "{{ steps.rows.output/0/__proto__ }}" }, scope)).toThrow(TemplateError);
  expect(fetchCalls).toBe(0);
});
