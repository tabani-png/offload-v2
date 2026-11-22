// Observations in, understanding window out (WINDOW): sessionize, describe, embed, induce. Pure apart from the
// injected embedder and labeler; the labeler's model call happens here, never inside a database transaction.
// No text snapshot content leaves this function: spans carry the masked title only, tasks a rules-made name.
import { dayOf } from "../records/dates.ts";
import type { DayLabel, UnderstandingWindow, WindowSpan } from "../user-model/ports.ts";
import { describeSpans } from "./describe.ts";
import { localEmbedder, type Embedder } from "./embed.ts";
import { induceTasks } from "./induce.ts";
import type { SpanLabeler } from "./labeler.ts";
import { sessionize } from "./sessionize.ts";
import type { CaptureObservation, CaptureText } from "./types.ts";

export interface WindowInput {
  /** IANA timezone of the member (the profile's): days and instance splits use it. */
  timezone: string;
  /** The days to analyse, member-timezone labels. Spans starting on other days are dropped. */
  days: DayLabel[];
  observations: readonly CaptureObservation[];
  texts: readonly CaptureText[];
}

export interface WindowDeps {
  embedder?: Embedder;
  labeler?: SpanLabeler;
}

export async function buildUnderstandingWindow(input: WindowInput, deps: WindowDeps = {}): Promise<UnderstandingWindow> {
  const days = [...new Set(input.days)].sort();
  const wanted = new Set(days);
  const spans = sessionize(input.observations, input.texts).filter((s) => wanted.has(dayOf(s.start, input.timezone)));
  const descs = await describeSpans(spans, input.timezone, deps.labeler);
  const joinable = descs.filter((d) => d.joinable);
  const embedder = deps.embedder ?? localEmbedder();
  const vecs = joinable.length === 0 ? [] : await embedder.embed(joinable.map((d) => d.text));
  const vectors = new Map(joinable.map((d, i) => [d.spanId, vecs[i]!]));
  const tasks = induceTasks(descs, vectors, input.timezone);
  const windowSpans: WindowSpan[] = spans.map((s) => ({
    id: s.id,
    start: s.start,
    end: s.end,
    activeSeconds: Math.round(s.activeMs / 1000),
    appBundleId: s.appBundleId,
    appName: s.appName,
    host: s.host,
    title: s.title,
    observationIds: s.observationIds,
  }));
  return { timezone: input.timezone, days, spans: windowSpans, tasks };
}
