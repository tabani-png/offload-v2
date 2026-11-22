// The optional label route for span descriptions (m5-03 router, route `label`). Injected, never required.
import type { RouteCall } from "../models/router.ts";
import type { RouteResult } from "../models/types.ts";

export interface LabelItem {
  span_id: string;
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

export function routerSpanLabeler(_route: RouteFn, _who: { tenant_id: string; member_id: string }): SpanLabeler {
  throw new Error("not implemented");
}
