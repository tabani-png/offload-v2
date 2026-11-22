import { z } from "zod";
import { TemplateArgsSchema, TemplateError, templateRefs } from "./template.ts";

/**
 * routine.json (ADR 0026), with step placement from ADR 0025. zod is the source; scripts/gen-json-schema.ts exports
 * JSON Schema 2020-12 to schemas/. Every object is strict (additionalProperties: false).
 *
 * Per-class rules are expressed as one object shape per class, so JSON Schema states them too. Rules across steps
 * (unique ids, foreach and template references point at earlier steps, recipients_from names a step, every step
 * capability is listed, cron field ranges, IANA time zone) are zod refinements; JSON Schema cannot state them, so
 * validate with parseRoutine, not with the JSON Schema alone.
 */

/** Capabilities a `runs_on: "device"` commit step may use: the Mac actuator's typed commands (ADR 0025). */
export const DEVICE_CAPABILITIES = ["shortcut.run", "appleevent.template", "ax.action", "browser.step"] as const;
export type DeviceCapability = (typeof DEVICE_CAPABILITIES)[number];

const STEP_ID = /^[a-z][a-z0-9_]{0,31}$/;
export const StepIdSchema = z.string().regex(STEP_ID);
/** A capability from the fixed vocabulary, for example `mail.send`, `sheet.append`. */
export const CapabilitySchema = z.string().max(64).regex(/^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)+$/);
export const ConnectionRefSchema = z.string().regex(/^[a-z][a-z0-9_]{0,31}$/);
const RelPath = (dir: string, ext: string) =>
  z.string().max(200).regex(new RegExp(`^${dir}/[a-z0-9_-]+(/[a-z0-9_-]+)*\\.${ext}$`));
const HHMM = z.string().regex(/^([01][0-9]|2[0-3]):[0-5][0-9]$/);
const CRON_FIELD = "[0-9*/,-]+";
const CronSchema = z.string().regex(new RegExp(`^${CRON_FIELD}( ${CRON_FIELD}){4}$`));
const TimezoneSchema = z.string().max(64).regex(/^[A-Za-z][A-Za-z0-9_+-]*(\/[A-Za-z0-9_+-]+)*$/);
const EventTypeSchema = z.string().max(64).regex(/^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)+$/);

export const TriggerSchema = z.discriminatedUnion("kind", [
  z.strictObject({ kind: z.literal("schedule"), cron: CronSchema, timezone: TimezoneSchema.optional() }),
  z.strictObject({ kind: z.literal("webhook") }),
  z.strictObject({ kind: z.literal("event"), event_type: EventTypeSchema }),
  z.strictObject({ kind: z.literal("manual") }),
]);

const base = { id: StepIdSchema, args: TemplateArgsSchema, foreach: StepIdSchema.optional() };
const connector = { capability: CapabilitySchema, connection_ref: ConnectionRefSchema };
/** The connection pin fields (ADR 0032, ADR 0033). */
const pinned = {
  connection_id: z.string().regex(/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/),
  adapter: z.string().regex(/^[a-z][a-z0-9_]{0,31}$/),
  provider: z.string().regex(/^[a-z][a-z0-9_-]{0,63}$/),
  account_label: z.string().min(1).max(120),
  tool_name: z.string().min(1).max(128),
  tool_pin_hash: z.string().regex(/^[0-9a-f]{64}$/),
};
export const ModelCallSchema = z.strictObject({
  route: z.string().regex(/^[a-z][a-z0-9_]{0,31}$/),
  prompt_ref: RelPath("prompts", "md"),
  output_schema_ref: RelPath("schemas", "json"),
});

function stepSchemas<C extends typeof connector>(conn: C) {
  const cloud = z.literal("cloud");
  return z.union([
    z.strictObject({ ...base, class: z.literal("read"), runs_on: cloud, ...conn }),
    z.strictObject({ ...base, class: z.literal("draft"), runs_on: cloud, ...conn }),
    z.strictObject({ ...base, class: z.literal("commit"), runs_on: cloud, ...conn }),
    z.strictObject({ ...base, class: z.literal("commit"), runs_on: z.literal("device"), ...conn, capability: z.enum(DEVICE_CAPABILITIES) }),
    z.strictObject({ ...base, class: z.literal("transform"), runs_on: cloud, transform: RelPath("transforms", "ts") }),
    // model steps are tool-less: no capability, no connection, no tools (ADR 0026)
    z.strictObject({ ...base, class: z.literal("model"), runs_on: cloud, model: ModelCallSchema }),
  ]);
}

export const LimitsSchema = z.strictObject({
  max_items_per_run: z.int().min(1).max(500),
  max_runs_per_day: z.int().min(1).max(96),
  run_budget_usd: z.number().positive().max(4),
  quiet_hours: z.strictObject({ start: HHMM, end: HHMM }).nullable().optional(),
  recipients_from: StepIdSchema.optional(),
});

const PlainStepSchema = stepSchemas(connector);
/** Filled from the brief's pinned connections by resolveDefinition. */
const ResolvedStepSchema = stepSchemas({ ...connector, ...pinned });

function definitionSchema<S extends typeof PlainStepSchema | typeof ResolvedStepSchema>(steps: S) {
  return z
    .strictObject({
      v: z.literal(1),
      name: z.string().min(1).max(80),
      trigger: TriggerSchema,
      steps: z.array(steps).min(1).max(64),
      limits: LimitsSchema,
      capabilities: z.array(CapabilitySchema).max(64),
    })
    .superRefine((def, ctx) => crossStepRules(def as unknown as RuleView, ctx));
}

type RuleView = {
  trigger: Trigger;
  steps: { id: string; foreach?: string; args: unknown; capability?: string }[];
  limits: { recipients_from?: string };
  capabilities: string[];
};

function crossStepRules(def: RuleView, ctx: z.RefinementCtx): void {
  const issue = (path: (string | number)[], message: string) => ctx.addIssue({ code: "custom", path, message });
  const seen = new Set<string>();
  def.steps.forEach((step, i) => {
    if (seen.has(step.id)) issue(["steps", i, "id"], `duplicate step id ${step.id}`);
    if (step.foreach !== undefined && !seen.has(step.foreach)) issue(["steps", i, "foreach"], "foreach must name an earlier step");
    try {
      for (const ref of templateRefs(step.args)) {
        if (ref.kind === "step" && !seen.has(ref.step)) issue(["steps", i, "args"], `template refers to ${ref.step}, which is not an earlier step`);
        if (ref.kind === "item" && step.foreach === undefined) issue(["steps", i, "args"], "{{ item.* }} needs foreach");
      }
    } catch (e) {
      if (!(e instanceof TemplateError)) throw e;
      issue(["steps", i, "args"], e.message);
    }
    if (step.capability !== undefined && !def.capabilities.includes(step.capability)) {
      issue(["steps", i, "capability"], `capability ${step.capability} is not listed in capabilities`);
    }
    seen.add(step.id);
  });
  if (new Set(def.capabilities).size !== def.capabilities.length) issue(["capabilities"], "capabilities has duplicates");
  const rf = def.limits.recipients_from;
  if (rf !== undefined && !seen.has(rf)) issue(["limits", "recipients_from"], "recipients_from must name a step");
  if (def.trigger.kind === "schedule") {
    if (!cronInRange(def.trigger.cron)) issue(["trigger", "cron"], "cron field out of range");
    if (def.trigger.timezone !== undefined && !isIanaZone(def.trigger.timezone)) issue(["trigger", "timezone"], "unknown IANA time zone");
  }
}

export const RoutineDefinitionSchema = definitionSchema(PlainStepSchema);
/** routine.json after resolveDefinition: every connector step carries its connection pin. Hashed as definition_hash. */
export const ResolvedRoutineDefinitionSchema = definitionSchema(ResolvedStepSchema);

export type RoutineDefinition = z.infer<typeof RoutineDefinitionSchema>;
export type RoutineStep = RoutineDefinition["steps"][number];
export type ResolvedRoutineDefinition = z.infer<typeof ResolvedRoutineDefinitionSchema>;
export type ResolvedStep = ResolvedRoutineDefinition["steps"][number];
export type Trigger = z.infer<typeof TriggerSchema>;
export type Limits = z.infer<typeof LimitsSchema>;

/** Parses routine.json with every rule (shape and cross-step). Throws a ZodError. */
export function parseRoutine(doc: unknown): RoutineDefinition {
  return RoutineDefinitionSchema.parse(doc);
}

const CRON_RANGES: [number, number][] = [[0, 59], [0, 23], [1, 31], [1, 12], [0, 7]];

/** Every number in each of the 5 cron fields is inside that field's range; step values are at least 1. */
function cronInRange(cron: string): boolean {
  return cron.split(" ").every((field, i) => {
    const [lo, hi] = CRON_RANGES[i]!;
    return field.split(",").every((part) => {
      const m = /^(\*|(\d+)(?:-(\d+))?)(?:\/(\d+))?$/.exec(part);
      if (!m) return false;
      const nums = [m[2], m[3]].filter((x): x is string => x !== undefined).map(Number);
      if (nums.some((n) => n < lo || n > hi)) return false;
      if (nums.length === 2 && nums[0]! > nums[1]!) return false;
      return m[4] === undefined || Number(m[4]) >= 1;
    });
  });
}

function isIanaZone(tz: string): boolean {
  try {
    new Intl.DateTimeFormat("en-US", { timeZone: tz });
    return true;
  } catch {
    return false;
  }
}
