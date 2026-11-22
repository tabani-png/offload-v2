// Inputs and intermediate shapes of understanding (slice m5-01). Everything here is already masked and pseudonymised
// on the Mac (C1); understanding reads it and never stores or logs text.
import type { DayLabel } from "../user-model/ports.ts";

/** One `observations` row (DATA_MODEL section 5). `ts` is epoch milliseconds; absent fields are null. */
export interface CaptureObservation {
  device_id: string;
  object_id: string;
  ts: number;
  kind: "focus" | "idle_start" | "idle_end" | "input_counts" | "pause" | "resume" | "permission_change";
  app_bundle_id: string | null;
  app_name: string | null;
  /** Masked, pseudonymised window title. */
  title: string | null;
  host: string | null;
  /** `<doc:h_…>` pseudonym of the URL path or document id. */
  doc: string | null;
  keys: number | null;
  clicks: number | null;
  source: "live" | "import";
  import_id: string | null;
}

/** One `observation_texts` row: a masked text snapshot (Accessibility text, or OCR under 200 characters of AX). */
export interface CaptureText {
  device_id: string;
  object_id: string;
  ts: number;
  text: string;
  text_source: "ax" | "ocr";
  app_bundle_id: string | null;
}

/** A continuous focus interval on one app, title and host, idle removed (before description). */
export interface Span {
  /** uuid, deterministic from the device and the observation that opened it. */
  id: string;
  deviceId: string;
  start: number;
  end: number;
  activeMs: number;
  appBundleId: string;
  appName: string;
  title: string;
  host: string;
  /** `doc` pseudonyms from the focus events. */
  docs: string[];
  /** Object ids of the observations and texts behind the span (evidence). */
  observationIds: string[];
  /** Masked texts in time order. Never leaves understanding. */
  texts: string[];
  keys: number;
  clicks: number;
  /** The observed app was a stand-in (no menu bar named one). */
  standIn: boolean;
  /** App or host came from cues in the masked text. */
  cued: boolean;
}

export interface SpanDescription {
  spanId: string;
  day: DayLabel;
  start: number;
  end: number;
  activeMs: number;
  appBundleId: string;
  appName: string;
  host: string;
  verb: string;
  object: string;
  /** Every pseudonym seen (`<doc:h_…>`, `<person:h_…>`, `<email:h_…>`, `<phone:h_…>`), sorted. */
  pseudonyms: string[];
  /** The `<doc:h_…>` subset. */
  docs: string[];
  /** Content words: lowercase letters only, 3+ characters, no stop words, most frequent first. */
  words: string[];
  /** False for a stand-in span with no cue and no words: it counts as time but joins no task. */
  joinable: boolean;
  standIn: boolean;
  cued: boolean;
  /** Where verb and object came from. */
  verbFrom: "text" | "label" | "default";
  objectFrom: "text" | "label" | "none";
  /** The text that is embedded: surface, verb, object and content words. No pseudonyms, no digits. */
  text: string;
  /** Evidence ids, copied from the span. */
  observationIds: string[];
}
