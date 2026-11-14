// Input port of the user model: what understanding (sessionize, describe, induce; slice m5-01) hands over for one
// analysed window. This is a local stand-in until m5-01 lands; see slices/p43a-user-model-core/DESIGN.md section 4.
// Everything here is already masked and pseudonymised upstream. `title` is read for nothing and never stored.

/** A calendar day `YYYY-MM-DD` in the member's timezone (`profiles.timezone`). */
export type DayLabel = string;

/** A continuous focus interval on one app, title and host, idle removed. Times are epoch milliseconds. */
export interface WindowSpan {
  id: string;
  start: number;
  end: number;
  activeSeconds: number;
  appBundleId: string;
  appName: string;
  host: string;
  /** Masked, pseudonymised window title. Never stored by the user model. */
  title: string;
  /** Ids of the observations behind the span (evidence). */
  observationIds: string[];
}

/** One occurrence of an induced task. */
export interface WindowInstance {
  id: string;
  start: number;
  end: number;
  activeSeconds: number;
  spanIds: string[];
  observationIds: string[];
}

/** An induced task for this window. Its `id` is not stable across windows; the task ledger gives the stable key. */
export interface WindowTask {
  id: string;
  /** Rule signature (surface + verb + object). Hashed before it is stored. */
  signature: string;
  /** `<domain>.<verb>-<object>`, for example `email.outreach`. */
  kind: string;
  /** Masked verb-object name from rules or the `label` route. May still carry title words; scrubbed before storage. */
  name: string;
  appBundleId: string;
  appName: string;
  host: string;
  /** Mean step embedding (1024 dims in production), or null when the embedder did not run. */
  centroid: number[] | null;
  /** 0..1, how alike the instances look. */
  sameness: number;
  instances: WindowInstance[];
}

export interface UnderstandingWindow {
  /** IANA timezone of the member, from the profile. */
  timezone: string;
  /** The analysed days, oldest first. */
  days: DayLabel[];
  spans: WindowSpan[];
  tasks: WindowTask[];
}

/** Model completion through the model router (W1-F, m5-03). Gets a masked prompt, returns text. */
export type CompleteText = (prompt: string) => Promise<string>;
