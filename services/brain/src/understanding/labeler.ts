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

/** The label-only schema for `n` items. Each label names its item ("1".."n", a label like the others: schemas hold no
 * numbers), so an answer in another order still lands on the right span. */
export function labelSchema(n: number): JsonSchema {
  return {
    type: "object",
    properties: {
      labels: {
        type: "array",
        items: {
          type: "object",
          properties: {
            item: { type: "string", enum: Array.from({ length: n }, (_, i) => String(i + 1)) },
            verb: { type: "string", enum: [...SPAN_VERBS] },
            object: { type: "string", enum: [...SPAN_OBJECTS, "none"] },
          },
          required: ["item", "verb", "object"],
          additionalProperties: false,
        },
      },
    },
    required: ["labels"],
    additionalProperties: false,
  };
}

const SYSTEM =
  "You label short descriptions of screen work. For each numbered item give one verb and one object from the allowed " +
  "lists, and the item's number. Use the object none when no object fits.";

export function routerSpanLabeler(route: RouteFn, who: { tenant_id: string; member_id: string }): SpanLabeler {
  return {
    async label(items) {
      const out = new Map<string, SpanLabel>();
      if (items.length === 0) return out;
      const content = items.map((it, i) => `${i + 1}. ${untrusted("span_text", it.text)}`).join("\n");
      const r = await route({
        tenant_id: who.tenant_id, member_id: who.member_id, route: "label", system: SYSTEM, messages: [{ role: "user", content }],
        schema: labelSchema(items.length), max_tokens: 64 + 40 * items.length, scope: "brain",
      });
      if (r.status !== "ok") return out;
      const labels = (r.output as { labels?: unknown } | undefined)?.labels;
      if (!Array.isArray(labels)) return out;
      // Labels map to items by their item number. An item named twice gets no label (the answer contradicts itself);
      // an item not named gets none.
      const byItem = new Map<number, { verb?: unknown; object?: unknown }>();
      const repeated = new Set<number>();
      for (const raw of labels) {
        const l = raw as { item?: unknown; verb?: unknown; object?: unknown } | null;
        const k = typeof l?.item === "string" && /^[1-9]\d*$/.test(l.item) ? Number(l.item) - 1 : -1;
        if (k < 0 || k >= items.length) continue;
        if (byItem.has(k)) repeated.add(k);
        byItem.set(k, l!);
      }
      for (const [k, l] of byItem) {
        if (repeated.has(k)) continue;
        const verb = typeof l.verb === "string" && (SPAN_VERBS as readonly string[]).includes(l.verb) ? l.verb : undefined;
        const object = typeof l.object === "string" && (SPAN_OBJECTS as readonly string[]).includes(l.object) ? l.object : undefined;
        out.set(items[k]!.span_id, { ...(verb === undefined ? {} : { verb }), ...(object === undefined ? {} : { object }) });
      }
      return out;
    },
  };
}
