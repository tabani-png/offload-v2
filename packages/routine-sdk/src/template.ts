import { z } from "zod";

/**
 * Templates in step `args` (ADR 0026). A template string is plain text plus references, and nothing else:
 *   {{ steps.<id>.output<json pointer> }}   an earlier step's output, optionally narrowed by an RFC 6901 pointer
 *   {{ item.<field> }}                      a field of the current foreach item
 * No expressions, no filters, no calls. `{{` and `}}` may appear only as reference delimiters.
 * Example: "{{ steps.payouts.output/data/0/amount }}", "Appended {{ item.count }} rows".
 */

const STEP_ID = "[a-z][a-z0-9_]{0,31}";
const POINTER = "(?:/(?:[^~/{}\\s]|~[01])*)*";
const FIELD = "[A-Za-z_][A-Za-z0-9_]{0,63}";
const REF = `\\{\\{\\s*(?:steps\\.(${STEP_ID})\\.output(${POINTER})|item\\.(${FIELD}))\\s*\\}\\}`;

/** Whole-string pattern for a template string. The same text is the JSON Schema `pattern`. */
export const TEMPLATE_PATTERN = new RegExp(`^(?:[^{}]|\\{(?!\\{)|\\}(?!\\})|${REF})*$`);
const REF_GLOBAL = () => new RegExp(REF, "g");
const REF_WHOLE = new RegExp(`^${REF}$`);

export const TemplateStringSchema = z.string().max(4096).regex(TEMPLATE_PATTERN, "template: only {{ steps.<id>.output<pointer> }} and {{ item.<field> }} references");
export const ArgKeySchema = z.string().regex(/^[A-Za-z0-9_.-]{1,64}$/);

export type TemplateValue = string | TemplateValue[] | { [key: string]: TemplateValue };
export const TemplateValueSchema: z.ZodType<TemplateValue> = z.lazy(() =>
  z.union([TemplateStringSchema, z.array(TemplateValueSchema).max(256), z.record(ArgKeySchema, TemplateValueSchema)]),
);
/** `args` of a step: an object whose leaves are template strings. */
export const TemplateArgsSchema = z.record(ArgKeySchema, TemplateValueSchema);
export type TemplateArgs = z.infer<typeof TemplateArgsSchema>;

export type TemplateRef = { kind: "step"; step: string; pointer: string } | { kind: "item"; field: string };

export class TemplateError extends Error {
  override name = "TemplateError";
}

/** Values a template is rendered against: earlier step outputs and, inside foreach, the current item. */
export type TemplateScope = { steps: Readonly<Record<string, { output: unknown }>>; item?: unknown };

/** Every reference in a template value (deep). Throws TemplateError on a string that is not a template. */
export function templateRefs(value: unknown): TemplateRef[] {
  const out: TemplateRef[] = [];
  walkStrings(value, (s) => {
    if (!TEMPLATE_PATTERN.test(s)) throw new TemplateError("template has an expression or a stray {{ or }}");
    for (const m of s.matchAll(REF_GLOBAL())) out.push(toRef(m));
  });
  return out;
}

/**
 * Renders a template object. Pure: no I/O, the scope is not changed, and the result shares no objects with it.
 * A string that is exactly one reference becomes the referenced value (any JSON type); a reference inside text must
 * be a string, number or boolean and is joined as text.
 */
export function renderArgs(template: unknown, scope: TemplateScope): Record<string, unknown> {
  if (template === null || typeof template !== "object" || Array.isArray(template)) throw new TemplateError("args must be an object");
  return render(template, scope) as Record<string, unknown>;
}

function render(v: unknown, scope: TemplateScope): unknown {
  if (typeof v === "string") return renderString(v, scope);
  if (Array.isArray(v)) return v.map((x) => render(x, scope));
  if (v !== null && typeof v === "object") {
    const out: Record<string, unknown> = {};
    for (const [k, x] of Object.entries(v)) out[k] = render(x, scope);
    return out;
  }
  throw new TemplateError("template leaves must be strings");
}

function renderString(s: string, scope: TemplateScope): unknown {
  if (!TEMPLATE_PATTERN.test(s)) throw new TemplateError("template has an expression or a stray {{ or }}");
  const whole = REF_WHOLE.exec(s);
  if (whole) return copyJson(resolveRef(toRef(whole), scope));
  return s.replace(REF_GLOBAL(), (...m: unknown[]) => {
    const v = resolveRef(toRef(m as unknown as RegExpMatchArray), scope);
    if (typeof v === "string") return v;
    if (typeof v === "number" || typeof v === "boolean") return String(v);
    throw new TemplateError("only a string, number or boolean can be joined into text");
  });
}

function toRef(m: RegExpMatchArray | RegExpExecArray): TemplateRef {
  const [, step, pointer, field] = m;
  if (step !== undefined) return { kind: "step", step, pointer: pointer ?? "" };
  return { kind: "item", field: field ?? "" };
}

function resolveRef(ref: TemplateRef, scope: TemplateScope): unknown {
  if (ref.kind === "item") {
    if (!("item" in scope)) throw new TemplateError("{{ item.* }} is used outside foreach");
    return own(scope.item, ref.field, `item.${ref.field}`);
  }
  if (!Object.hasOwn(scope.steps, ref.step)) throw new TemplateError(`no output for step ${ref.step}`);
  let v: unknown = scope.steps[ref.step]?.output;
  if (ref.pointer === "") return v;
  for (const raw of ref.pointer.slice(1).split("/")) {
    const token = raw.replace(/~1/g, "/").replace(/~0/g, "~");
    v = own(v, token, `steps.${ref.step}.output${ref.pointer}`);
  }
  return v;
}

/** An own property of a JSON object or an index of an array; nothing from a prototype. */
function own(v: unknown, key: string, where: string): unknown {
  if (Array.isArray(v)) {
    if (!/^(0|[1-9][0-9]*)$/.test(key) || Number(key) >= v.length) throw new TemplateError(`${where} does not exist`);
    return v[Number(key)];
  }
  if (v !== null && typeof v === "object" && Object.hasOwn(v, key)) return (v as Record<string, unknown>)[key];
  throw new TemplateError(`${where} does not exist`);
}

function copyJson(v: unknown): unknown {
  if (v === undefined) throw new TemplateError("reference has no value");
  return JSON.parse(JSON.stringify(v)) as unknown;
}

function walkStrings(v: unknown, f: (s: string) => void): void {
  if (typeof v === "string") return f(v);
  if (Array.isArray(v)) return v.forEach((x) => walkStrings(x, f));
  if (v !== null && typeof v === "object") for (const x of Object.values(v)) walkStrings(x, f);
}
