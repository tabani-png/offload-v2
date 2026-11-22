// Span descriptions, rules first.
import type { DayLabel } from "../user-model/ports.ts";
import type { SpanLabeler } from "./labeler.ts";
import type { Span, SpanDescription } from "./types.ts";

export const SPAN_VERBS = ["create", "send", "reply", "approve", "reject", "submit", "pay", "export", "upload", "update", "reconcile", "schedule", "search", "attend", "read", "write", "edit", "view"] as const;
export const SPAN_OBJECTS = [
  "invoice", "bill", "order", "ticket", "customer", "contact", "deal", "lead", "report", "payment", "expense", "receipt", "shipment",
  "timesheet", "contract", "quote", "candidate", "claim", "booking", "refund", "statement", "document", "task", "project",
] as const;
export type SpanVerb = (typeof SPAN_VERBS)[number];
export type SpanObject = (typeof SPAN_OBJECTS)[number];

export function describeSpan(_span: Span, _timezone: string): SpanDescription {
  throw new Error("not implemented");
}

export async function describeSpans(_spans: readonly Span[], _timezone: string, _labeler?: SpanLabeler): Promise<SpanDescription[]> {
  throw new Error("not implemented");
}

export type { DayLabel };
