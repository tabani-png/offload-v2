// The optional `label` route for span descriptions (m5-03 router). Injected, never required, never called in tests
// against a provider. The model sees description words wrapped as untrusted data and answers with labels from the
// fixed vocabularies only (a label-only schema); code checks every value again (describe.ts).
import type { RouteCall } from "../models/router.ts";
import type { JsonSchema, RouteResult } from "../models/types.ts";
import { untrusted } from "../models/untrusted.ts";
import { SPAN_OBJECTS, SPAN_VERBS } from "./describe.ts";

export interface LabelItem {
  span_id: string;
  /** Masked description words, never raw snapshot text. */
  text: string;
}

export interface SpanLabel {
  verb?: string;
  object?: string;
}

export interface SpanLabeler {
  label(items: readonly LabelItem[]): Promise<Map<string, SpanLabel>>;
}

export type RouteFn = (call: RouteCall) => Promise<RouteResult>;

export const LABEL_SCHEMA: JsonSchema = {
  type: "object",
  properties: {
    labels: {
      type: "array",
      items: {
        type: "object",
        properties: { verb: { type: "string", enum: [...SPAN_VERBS] }, object: { type: "string", enum: [...SPAN_OBJECTS, "none"] } },
        required: ["verb", "object"],
        additionalProperties: false,
      },
    },
  },
  required: ["labels"],
  additionalProperties: false,
};

const SYSTEM =
  "You label short descriptions of screen work. For each numbered item give one verb and one object from the allowed " +
  "lists, in the same order as the items. Use the object none when no object fits.";

export function routerSpanLabeler(route: RouteFn, who: { tenant_id: string; member_id: string }): SpanLabeler {
  return {
    async label(items) {
      const out = new Map<string, SpanLabel>();
      if (items.length === 0) return out;
      const content = items.map((it, i) => `${i + 1}. ${untrusted("span_text", it.text)}`).join("\n");
      const r = await route({
        tenant_id: who.tenant_id, member_id: who.member_id, route: "label", system: SYSTEM, messages: [{ role: "user", content }],
        schema: LABEL_SCHEMA, max_tokens: 64 + 32 * items.length, scope: "brain",
      });
      if (r.status !== "ok") return out;
      const labels = (r.output as { labels?: unknown } | undefined)?.labels;
      if (!Array.isArray(labels) || labels.length !== items.length) return out;
      items.forEach((it, i) => {
        const l = labels[i] as { verb?: unknown; object?: unknown } | undefined;
        const verb = typeof l?.verb === "string" && (SPAN_VERBS as readonly string[]).includes(l.verb) ? l.verb : undefined;
        const object = typeof l?.object === "string" && (SPAN_OBJECTS as readonly string[]).includes(l.object) ? l.object : undefined;
        out.set(it.span_id, { ...(verb === undefined ? {} : { verb }), ...(object === undefined ? {} : { object }) });
      });
      return out;
    },
  };
}
