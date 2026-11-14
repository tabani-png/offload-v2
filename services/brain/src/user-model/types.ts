// Propositions: gum-style statements about the user (GeneralUserModels/gum, MIT: text, 1..10 confidence, 1..10 decay,
// revision group) with graphiti-style bi-temporal fields (getzep/graphiti, Apache-2.0: valid_at, invalid_at,
// expired_at, created_at, here recorded_at). Ideas and data shapes only; no code copied. See NOTICE.
import type { DayLabel } from "./ports.ts";

/** `sequence` waits for M7 (MIGRATION 5.4). */
export type PropositionKind = "repeats" | "time_share";

export interface Subject {
  taskKey: string;
  taskKind: string;
  /** Masked name. */
  name: string;
  appName: string;
  host: string;
}

export interface DayEvidence {
  instances: number;
  minutes: number;
}

export interface PropositionEvidence {
  instances: number;
  days: number;
  minutes: number;
  dayList: DayLabel[];
  /** Counts only, per member-timezone day. */
  perDay: Record<DayLabel, DayEvidence>;
  sameness: number;
  medianMinutes: number;
  /** time_share: share of active time in the latest window. */
  share: number;
  /** When the pattern was last seen (epoch ms). */
  lastSeenAt: number;
  reasoning: string;
  subject: Subject;
}

export interface Proposition {
  /** `p_` + 10 hex + `_v` + version. */
  id: string;
  /** `${kind}:${taskKey}`: every version of one belief. */
  key: string;
  kind: PropositionKind;
  version: number;
  revisionGroup: string;
  text: string;
  /** gum scale 1..10, computed by rule. */
  confidence: number;
  /** 0..1, the score behind `confidence`. */
  confidenceScore: number;
  /** gum scale 1..10. */
  decay: number;
  /** Per active day (repeats) or share (time_share): the number whose change makes a new version. */
  rate: number;
  evidence: PropositionEvidence;
  /** graphiti valid_at: first sighting (epoch ms). */
  validAt: number;
  /** graphiti invalid_at: when it stopped being true; null while current. */
  invalidAt: number | null;
  /** graphiti created_at: when Offload recorded this version. */
  recordedAt: number;
  /** graphiti expired_at: when Offload learned it stopped. */
  expiredAt: number | null;
}
