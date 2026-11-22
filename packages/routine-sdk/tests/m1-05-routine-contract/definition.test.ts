import { expect, test } from "bun:test";
import { jcs, sha256Hex } from "@offload/contracts";
import {
  ManifestError, ResolveError, checkManifest, definitionHash, describeDefinition, parseRoutine, resolveDefinition,
} from "../../src/index.ts";
import { PIN_HASH_B, edited, pins, validRoutine } from "./fixtures.ts";

const brief = () => ({ capabilities: ["payouts.list", "mail.draft", "sheet.append", "shortcut.run"], connections: pins() });

test("ROUTINE: definitionHash changes when a connection_id or tool pin changes", () => {
  const def = parseRoutine(validRoutine());
  const resolved = resolveDefinition(def, pins());
  const h = definitionHash(resolved);
  expect(h).toMatch(/^[0-9a-f]{64}$/);
  expect(h).toBe(sha256Hex(jcs(resolved)));
  expect(definitionHash(resolveDefinition(def, pins()))).toBe(h); // deterministic
  const append = resolved.steps.find((s) => s.id === "append")!;
  expect(append).toMatchObject({
    connection_id: "0193a000-0000-7000-8000-000000000003", adapter: "mcp", provider: "google",
    account_label: "your Workspace account", tool_name: "append_row", tool_pin_hash: "a".repeat(64),
  });

  const otherConnection = pins();
  otherConnection[2]!.connection_id = "0193a000-0000-7000-8000-0000000000ff";
  expect(definitionHash(resolveDefinition(def, otherConnection))).not.toBe(h);

  const otherPin = pins();
  otherPin[2]!.tools[0]!.tool_pin_hash = PIN_HASH_B;
  expect(definitionHash(resolveDefinition(def, otherPin))).not.toBe(h);

  const otherAccount = pins();
  otherAccount[0]!.account_label = "acme-test";
  expect(definitionHash(resolveDefinition(def, otherAccount))).not.toBe(h);

  // the limits are part of the hash
  const lower = parseRoutine(edited((r) => (r.limits.max_items_per_run = 10)));
  expect(definitionHash(resolveDefinition(lower, pins()))).not.toBe(h);

  // a missing connection or tool pin cannot be resolved
  expect(() => resolveDefinition(def, pins().slice(1))).toThrow(ResolveError);
  const noTool = pins();
  noTool[0]!.tools = [];
  expect(() => resolveDefinition(def, noTool)).toThrow(ResolveError);
  // a resolved definition that was changed after resolving is refused by definitionHash
  expect(() => definitionHash({ ...resolved, extra: 1 } as typeof resolved)).toThrow();
});

test("ROUTINE: describeDefinition names the account and limits for every step", () => {
  const resolved = resolveDefinition(parseRoutine(validRoutine()), pins());
  expect(describeDefinition(resolved)).toEqual([
    'Runs on the schedule "0 9 * * 1" (Europe/London).',
    "Step payouts: reads payouts.list (stripe · acme-live).",
    "Step rows: runs transforms/payouts_to_rows.ts, with no network.",
    "Step draft_note: drafts mail.draft (google · your Workspace account). Sends nothing.",
    "Step append: commits sheet.append (google · your Workspace account) for each item from step rows.",
    "Step summary: asks model route classify for structured output, with no tools.",
    "Step notify: commits shortcut.run on your Mac (mac · Mac 1).",
    "At most 50 items a run and 1 run a day. Run budget $0.50.",
    "Quiet hours 01:00 to 03:59.",
    "Recipients only from step payouts.",
  ]);
  const manual = resolveDefinition(
    parseRoutine(edited((r) => {
      r.trigger = { kind: "manual" };
      r.limits = { max_items_per_run: 1, max_runs_per_day: 4, run_budget_usd: 4, quiet_hours: null };
    })),
    pins(),
  );
  const words = describeDefinition(manual);
  expect(words[0]).toBe("Runs when you start it.");
  expect(words.slice(-2)).toEqual(["At most 1 item a run and 4 runs a day. Run budget $4.00.", "No quiet hours."]);
  expect(describeDefinition(resolveDefinition(parseRoutine(edited((r) => (r.trigger = { kind: "event", event_type: "batch.approved" }))), pins()))[0])
    .toBe('Runs on the Offload event "batch.approved".');
  expect(describeDefinition(resolveDefinition(parseRoutine(edited((r) => (r.trigger = { kind: "webhook" }))), pins()))[0])
    .toBe("Runs when its webhook is called.");
  expect(describeDefinition(resolveDefinition(parseRoutine(edited((r) => delete r.trigger.timezone)), pins()))[0])
    .toBe('Runs on the schedule "0 9 * * 1" (your time zone).');
});

test("ROUTINE: checkManifest refuses a capability not in the brief", () => {
  const def = parseRoutine(validRoutine());
  expect(() => checkManifest(def, brief())).not.toThrow();
  const fewer = { ...brief(), capabilities: ["payouts.list", "mail.draft", "sheet.append"] };
  expect(() => checkManifest(def, fewer)).toThrow(ManifestError);
  try {
    checkManifest(def, fewer);
  } catch (e) {
    expect((e as ManifestError).code).toBe("capability_not_in_brief");
    expect((e as ManifestError).message).toContain("shortcut.run");
  }
  // a connection_ref the brief does not pin is refused too
  const noMac = { ...brief(), connections: pins().filter((p) => p.connection_ref !== "mac") };
  try {
    checkManifest(def, noMac);
    throw new Error("expected a ManifestError");
  } catch (e) {
    expect(e).toBeInstanceOf(ManifestError);
    expect((e as ManifestError).code).toBe("connection_not_in_brief");
  }
  // a capability listed in the manifest but not used by a step still has to be in the brief
  const extra = parseRoutine(edited((r) => r.capabilities.push("mail.send")));
  expect(() => checkManifest(extra, brief())).toThrow(ManifestError);
});
