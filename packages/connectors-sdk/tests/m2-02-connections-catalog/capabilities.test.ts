import { expect, test } from "bun:test";
import { CapabilitySchema } from "@offload/contracts/src/connections/index.ts";
import {
  CAPABILITIES,
  CAPABILITY_DEFS,
  CapabilityLoadError,
  capabilityNames,
  findCapability,
  loadCapabilities,
} from "../../src/capabilities.ts";

const recipientsSchema = {
  type: "object",
  properties: { to: { type: "string" }, subject: { type: "string" }, body: { type: "string" } },
  required: ["to", "subject", "body"],
  additionalProperties: false,
};

function expectLoadError(defs: unknown[]): void {
  let caught: unknown = null;
  try {
    loadCapabilities(defs);
  } catch (err) {
    caught = err;
  }
  expect(caught).toBeInstanceOf(CapabilityLoadError);
  expect((caught as CapabilityLoadError).code).toBe("capability_invalid");
}

test("CAPABILITY: a commit capability without an argument allowlist fails to load", () => {
  expectLoadError([{ name: "mail.send", step_class: "commit", argument_schema: recipientsSchema }]);

  // An allowlist naming a property that is not in argument_schema.
  expectLoadError([
    {
      name: "mail.send",
      step_class: "commit",
      argument_schema: recipientsSchema,
      commit_arguments_allowlist: ["to", "bcc"],
    },
  ]);

  // A duplicate name.
  const ok = {
    name: "mail.send",
    step_class: "commit",
    argument_schema: recipientsSchema,
    commit_arguments_allowlist: ["to", "subject", "body"],
  };
  expectLoadError([ok, { ...ok }]);

  // A non-commit capability carrying an allowlist.
  expectLoadError([
    { name: "mail.read", step_class: "read", argument_schema: recipientsSchema, commit_arguments_allowlist: ["to"] },
  ]);

  // Not a Capability at all.
  expectLoadError([{ name: "Mail Send", step_class: "commit", argument_schema: recipientsSchema }]);

  // The well-formed one loads.
  expect(loadCapabilities([ok])).toEqual([ok as never]);
});

test("CAPABILITY: the shipped vocabulary loads and every commit capability has an argument allowlist", () => {
  expect(() => loadCapabilities([...CAPABILITY_DEFS])).not.toThrow();
  expect(CAPABILITIES.length).toBe(CAPABILITY_DEFS.length);

  const names = capabilityNames();
  expect(new Set(names).size).toBe(names.length);
  for (const required of ["mail.send", "sheet.append", "sheet.read", "calendar.events", "payouts.list"]) {
    expect(names).toContain(required);
  }
  expect(findCapability("mail.send")?.step_class).toBe("commit");
  expect(findCapability("sheet.append")?.step_class).toBe("commit");
  expect(findCapability("sheet.read")?.step_class).toBe("read");
  expect(findCapability("payouts.list")?.step_class).toBe("read");
  expect(findCapability("not.a_capability")).toBeUndefined();

  for (const cap of CAPABILITIES) {
    expect(CapabilitySchema.parse(cap)).toEqual(cap);
    expect(cap.argument_schema["type"]).toBe("object");
    const props = Object.keys((cap.argument_schema["properties"] ?? {}) as Record<string, unknown>);
    if (cap.step_class === "commit") {
      expect(cap.commit_arguments_allowlist?.length ?? 0).toBeGreaterThan(0);
      for (const arg of cap.commit_arguments_allowlist ?? []) expect(props).toContain(arg);
    } else {
      expect(cap.commit_arguments_allowlist).toBeUndefined();
    }
  }
});
