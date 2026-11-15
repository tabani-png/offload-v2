import { expect, test } from "bun:test";
import { readFileSync, readdirSync } from "node:fs";
import { join } from "node:path";
import Ajv2020 from "ajv/dist/2020.js";
import { DEVICE_CAPABILITIES, RoutineDefinitionSchema, parseRoutine } from "../../src/index.ts";
import { generateSchemas } from "../../scripts/gen-json-schema.ts";
import { edited, validRoutine } from "./fixtures.ts";

const SCHEMA_DIR = join(import.meta.dir, "../../schemas");
const readSchema = (name: string) => JSON.parse(readFileSync(join(SCHEMA_DIR, `${name}.schema.json`), "utf8"));
const ajv = () => new Ajv2020({ strict: true, validateFormats: false });

/** zod and the committed JSON Schema agree on `doc`. */
function bothReject(doc: unknown): void {
  expect(RoutineDefinitionSchema.safeParse(doc).success).toBe(false);
  expect(ajv().compile(readSchema("routine"))(doc)).toBe(false);
}
const zodRejects = (doc: unknown) => expect(RoutineDefinitionSchema.safeParse(doc).success).toBe(false);

test("ROUTINE: a valid routine.json round-trips zod ↔ JSON Schema 2020-12", () => {
  const doc = validRoutine();
  const parsed = RoutineDefinitionSchema.parse(doc);
  expect(parsed).toEqual(doc as typeof parsed);
  expect(JSON.parse(JSON.stringify(parsed))).toEqual(doc);
  const validate = ajv().compile(readSchema("routine"));
  expect(validate(doc)).toBe(true);
  expect(validate(JSON.parse(JSON.stringify(parsed)))).toBe(true);
  // the other triggers are valid too
  for (const trigger of [{ kind: "manual" }, { kind: "webhook" }, { kind: "event", event_type: "batch.approved" }]) {
    const d = edited((r) => (r.trigger = trigger));
    expect(RoutineDefinitionSchema.safeParse(d).success).toBe(true);
    expect(validate(d)).toBe(true);
  }
  // quiet_hours may be null
  expect(validate(edited((r) => (r.limits.quiet_hours = null)))).toBe(true);
  expect(parseRoutine(edited((r) => (r.limits.quiet_hours = null))).limits.quiet_hours).toBeNull();
});

test("ROUTINE: generated routine schemas are fresh", () => {
  const generated = generateSchemas();
  const names = Object.keys(generated).sort();
  expect(names).toEqual(["resolved-routine.schema.json", "routine.schema.json"]);
  expect(readdirSync(SCHEMA_DIR).sort()).toEqual(names);
  for (const name of names) {
    expect(readFileSync(join(SCHEMA_DIR, name), "utf8")).toBe(generated[name]!);
    const doc = JSON.parse(generated[name]!);
    expect(doc.$schema).toBe("https://json-schema.org/draft/2020-12/schema");
  }
});

test("ROUTINE: unknown fields anywhere are rejected", () => {
  bothReject(edited((r) => (r.extra = 1)));
  bothReject(edited((r) => (r.trigger.extra = 1)));
  bothReject(edited((r) => (r.steps[0].extra = 1)));
  bothReject(edited((r) => (r.steps[1].extra = 1)));
  bothReject(edited((r) => (r.steps[4].model.extra = 1)));
  bothReject(edited((r) => (r.limits.extra = 1)));
  bothReject(edited((r) => (r.limits.quiet_hours.extra = 1)));
  bothReject(edited((r) => (r.v = 2)));
  // every object node in the generated schemas closes its properties
  for (const name of ["routine", "resolved-routine"]) {
    const open: string[] = [];
    const walk = (n: unknown, path: string): void => {
      if (Array.isArray(n)) return n.forEach((x, i) => walk(x, `${path}/${i}`));
      if (n === null || typeof n !== "object") return;
      const o = n as Record<string, unknown>;
      if ("properties" in o && o["additionalProperties"] !== false) open.push(path);
      for (const [k, v] of Object.entries(o)) walk(v, `${path}/${k}`);
    };
    walk(readSchema(name), "");
    expect(open).toEqual([]);
  }
});

test("ROUTINE: a commit step without capability or connection_ref is rejected", () => {
  bothReject(edited((r) => delete r.steps[3].capability));
  bothReject(edited((r) => delete r.steps[3].connection_ref));
  bothReject(edited((r) => delete r.steps[0].capability)); // read
  bothReject(edited((r) => delete r.steps[2].connection_ref)); // draft
  // transform steps need a transform and take no capability
  bothReject(edited((r) => delete r.steps[1].transform));
  bothReject(edited((r) => (r.steps[1].capability = "payouts.list")));
  bothReject(edited((r) => (r.steps[1].transform = "../escape.ts")));
  bothReject(edited((r) => (r.steps[1].transform = "lib/rows.ts")));
});

test("ROUTINE: a model step with a capability is rejected", () => {
  bothReject(edited((r) => (r.steps[4].capability = "mail.send")));
  bothReject(edited((r) => (r.steps[4].connection_ref = "gmail")));
  bothReject(edited((r) => (r.steps[4].tools = ["mail.send"])));
  bothReject(edited((r) => delete r.steps[4].model));
  bothReject(edited((r) => delete r.steps[4].model.output_schema_ref));
  bothReject(edited((r) => (r.steps[4].runs_on = "device")));
});

test("ROUTINE: runs_on device is rejected for read, draft and non-device capabilities", () => {
  expect([...DEVICE_CAPABILITIES].sort()).toEqual(["appleevent.template", "ax.action", "browser.step", "shortcut.run"]);
  bothReject(edited((r) => (r.steps[0].runs_on = "device"))); // read
  bothReject(edited((r) => (r.steps[2].runs_on = "device"))); // draft
  bothReject(edited((r) => (r.steps[1].runs_on = "device"))); // transform
  bothReject(edited((r) => (r.steps[3].runs_on = "device"))); // commit sheet.append is not a device capability
  bothReject(edited((r) => (r.steps[5].runs_on = "elsewhere")));
  // each device capability is fine on a device commit
  for (const cap of DEVICE_CAPABILITIES) {
    const d = edited((r) => {
      r.steps[5].capability = cap;
      r.capabilities[3] = cap;
    });
    expect(RoutineDefinitionSchema.safeParse(d).success).toBe(true);
  }
  // the SPEC restricts device placement only; a commit with a device capability may run in the cloud (ADR 0025: browser.step for service accounts)
  expect(RoutineDefinitionSchema.safeParse(edited((r) => (r.steps[5].runs_on = "cloud"))).success).toBe(true);
});

test("ROUTINE: foreach must name an earlier step", () => {
  zodRejects(edited((r) => (r.steps[3].foreach = "summary"))); // later step
  zodRejects(edited((r) => (r.steps[3].foreach = "append"))); // itself
  zodRejects(edited((r) => (r.steps[3].foreach = "nope"))); // unknown
  bothReject(edited((r) => (r.steps[3].foreach = "Bad Id")));
  // step references in templates obey the same order
  zodRejects(edited((r) => (r.steps[1].args = { x: "{{ steps.summary.output }}" })));
  zodRejects(edited((r) => (r.steps[1].args = { x: "{{ steps.nope.output }}" })));
  // item.* needs foreach
  zodRejects(edited((r) => (r.steps[2].args = { x: "{{ item.date }}" })));
  // ids are unique and well formed; recipients_from names a step; capabilities cover every step
  zodRejects(edited((r) => (r.steps[1].id = "payouts")));
  bothReject(edited((r) => (r.steps[0].id = "9lives")));
  zodRejects(edited((r) => (r.limits.recipients_from = "nope")));
  zodRejects(edited((r) => (r.capabilities = ["payouts.list", "mail.draft", "sheet.append"])));
  zodRejects(edited((r) => r.capabilities.push("payouts.list"))); // duplicate
  const res = RoutineDefinitionSchema.safeParse(edited((r) => (r.steps[3].foreach = "summary")));
  expect(res.success).toBe(false);
  expect(JSON.stringify(res.error?.issues)).toContain("foreach");
});

test("ROUTINE: a template with an expression is rejected", () => {
  const bad = [
    "{{ 1 + 1 }}", "{{ item.a || x }}", "{{ steps.payouts.output/data | upper }}", "{{ item.a.b() }}",
    "{{ constructor }}", "{{ steps.payouts }}", "{{steps.payouts.output}} {{", "}}", "{{ item.date }", "{{ `x` }}",
    "{{ steps.payouts.output/data/~2 }}", "{{ item }}", "{{ globalThis.fetch }}",
  ];
  for (const t of bad) {
    const d = edited((r) => (r.steps[3].args = { values: [t] }));
    expect({ t, ok: RoutineDefinitionSchema.safeParse(d).success }).toEqual({ t, ok: false });
    expect({ t, ok: ajv().compile(readSchema("routine"))(d) }).toEqual({ t, ok: false });
  }
  // plain text, references and single braces are fine
  for (const t of ["plain", "{{ item.date }}", "{{item.amount}}", "{ not a ref }", "{{ steps.payouts.output }}", "{{ steps.payouts.output/data/0/a~1b }}"]) {
    const d = edited((r) => (r.steps[3].args = { values: [t] }));
    expect({ t, ok: RoutineDefinitionSchema.safeParse(d).success }).toEqual({ t, ok: true });
  }
  // args leaves must be strings: no numbers, booleans or null
  bothReject(edited((r) => (r.steps[0].args = { limit: 50 })));
  bothReject(edited((r) => (r.steps[0].args = { limit: null })));
});

test("ROUTINE: run_budget_usd above 4.00 is rejected", () => {
  bothReject(edited((r) => (r.limits.run_budget_usd = 4.01)));
  bothReject(edited((r) => (r.limits.run_budget_usd = 0)));
  bothReject(edited((r) => (r.limits.run_budget_usd = -1)));
  expect(RoutineDefinitionSchema.safeParse(edited((r) => (r.limits.run_budget_usd = 4))).success).toBe(true);
  bothReject(edited((r) => (r.limits.max_items_per_run = 501)));
  bothReject(edited((r) => (r.limits.max_items_per_run = 0)));
  bothReject(edited((r) => (r.limits.max_runs_per_day = 97)));
  bothReject(edited((r) => (r.limits.max_runs_per_day = 1.5)));
  bothReject(edited((r) => (r.limits.quiet_hours = { start: "24:00", end: "03:59" })));
  bothReject(edited((r) => (r.name = "x".repeat(81))));
  bothReject(edited((r) => (r.trigger = { kind: "schedule", cron: "0 9 * *" })));
  bothReject(edited((r) => (r.trigger = { kind: "schedule" })));
  bothReject(edited((r) => (r.trigger = { kind: "event" })));
  bothReject(edited((r) => (r.trigger = { kind: "manual", cron: "0 9 * * 1" })));
  zodRejects(edited((r) => (r.trigger.timezone = "Mars/Olympus_Mons")));
});
