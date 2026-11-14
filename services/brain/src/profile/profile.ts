// The profile (old brain/src/profile/store.ts validation rules, rewritten for DATA_MODEL `profiles` and `goals`).
// What the user told Offload. No field is ever used as a number; goals weight ranking through code only.
import type { UserContext } from "../understanding/context.ts";

export const DRAINS = ["email", "meetings", "agent_babysitting", "reporting", "content", "admin", "context_switching"] as const;
export type Drain = (typeof DRAINS)[number];
export const AUTONOMY = ["suggest", "draft", "run_approved"] as const;
export type Autonomy = (typeof AUTONOMY)[number];
export const WEEKDAYS = ["mon", "tue", "wed", "thu", "fri", "sat", "sun"] as const;
export type Weekday = (typeof WEEKDAYS)[number];
export const OWN_NAME = ["mask", "keep"] as const;
export const MAX_GOALS = 3;
export const GOAL_MAX_CHARS = 80;

export interface Goal {
  /** `g_` + first 10 hex of sha256(lowercased text + created_at). */
  id: string;
  text: string;
  horizon: "90d";
  created_at: string;
  archived_at: string | null;
}

export interface Profile {
  /** Bumped on every edit; 0 = never edited. */
  version: number;
  role: string | null;
  industry: string | null;
  /** Active goals, in the order the user gave them. */
  goals: Goal[];
  drains: Drain[];
  schedule: { days: Weekday[]; start: string; end: string } | null;
  timezone: string;
  review_slot: { day: Weekday; time: string };
  autonomy: Autonomy;
  own_name_to_models: (typeof OWN_NAME)[number];
  keyframes_to_cloud: boolean;
  learning_paused: boolean;
  updated_at: string | null;
}

export type PatchResult =
  | { ok: true; profile: Profile; added: Goal[]; archived: Goal[] }
  | { ok: false; message: string };

export function defaultProfile(): Profile {
  throw new Error("not implemented");
}
export function goalId(_text: string, _createdAt: string): string {
  throw new Error("not implemented");
}
/** Validates a partial PATCH body against the current profile. */
export function applyProfilePatch(_current: Profile, _body: unknown, _now: number): PatchResult {
  throw new Error("not implemented");
}
export function userContextOf(_p: Profile): UserContext {
  throw new Error("not implemented");
}
