// Understanding (slice m5-01): observations and masked text in, an understanding window out.
// See docs/ARCHITECTURE.md section 5 and slices/m5-01-understanding/SPEC.md.
export type { CaptureObservation, CaptureText, Span, SpanDescription } from "./types.ts";
export { sessionize, SESSION, type SessionOptions } from "./sessionize.ts";
export { cueOf, isStandInApp, type Cue } from "./cues.ts";
export { describeSpan, describeSpans, SPAN_OBJECTS, SPAN_VERBS } from "./describe.ts";
export { cosine, EMBED_DIMS, localEmbedder, type Embedder } from "./embed.ts";
export { induceTasks, INDUCE, type InduceOptions } from "./induce.ts";
export { routerSpanLabeler, type LabelItem, type SpanLabel, type SpanLabeler } from "./labeler.ts";
export { buildUnderstandingWindow, type WindowDeps, type WindowInput } from "./window.ts";
export { MAX_ATTEMPTS as UNDERSTANDING_MAX_ATTEMPTS, pgCaptureStore, type CaptureStoreOptions, UNDERSTANDING_CONSUMER, type CaptureStore, type IngestedEvent, type MemberRef } from "./capture.ts";
export { drainUnderstanding, LIVE_LATE_DAYS, MAX_ANALYSIS_DAYS, MAX_RANGE_DAYS, runUnderstanding, understandingWorkflow, type UnderstandingDeps, type UnderstandingResult, type UnderstandingStatus } from "./job.ts";
