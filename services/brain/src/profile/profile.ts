// The profile (old brain/src/profile/store.ts validation rules, rewritten for DATA_MODEL `profiles` and `goals`).
// What the user told Offload. No field is ever used as a number; goals weight ranking through code only and reach a
// model only inside the <user_context> block.
import { createHash } from "node:crypto";
import { isValidTimezone } from "../records/dates.ts";
import { sanitizeUserContext, type UserContext } from "../understanding/context.ts";
import { hasLink } from "../user-model/names.ts";

export const DRAINS = ["email", "meetings", "agent_babysitting", "reporting", "content", "admin", "context_switching"] as const;
export type Drain = (typeof DRAINS)[number];
export const AUTONOMY = ["suggest", "draft", "run_approved"] as const;
export type Autonomy = (typeof AUTONOMY)[number];
export const WEEKDAYS = ["mon", "tue", "wed", "thu", "fri", "sat", "sun"] as const;
export type Weekday = (typeof WEEKDAYS)[number];
export const OWN_NAME = ["mask", "keep"] as const;
export const MAX_GOALS = 3;
export const GOAL_MAX_CHARS = 80;
/** Fields PATCH /v1/profile may change. `version`, `updated_at` and `learning_paused` (POST /v1/learning/*) may not. */
export const PATCHABLE = ["role", "industry", "goals", "drains", "schedule", "timezone", "review_slot", "autonomy", "own_name_to_models", "keyframes_to_cloud"] as const;

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

const TIME_RE = /^(?:[01]\d|2[0-3]):[0-5]\d$/;

class Invalid extends Error {}
const fail = (message: string): never => {
  throw new Invalid(message);
};
const isObject = (v: unknown): v is Record<string, unknown> => typeof v === "object" && v !== null && !Array.isArray(v);
const oneOf = <T extends string>(field: string, v: unknown, values: readonly T[]): T =>
  typeof v === "string" && (values as readonly string[]).includes(v) ? (v as T) : fail(`${field} must be one of ${values.join(", ")}`);
const exactKeys = (field: string, v: Record<string, unknown>, keys: readonly string[]) => {
  for (const k of Object.keys(v)) if (!keys.includes(k)) fail(`${field}.${k} is not a field`);
  for (const k of keys) if (!(k in v)) fail(`${field}.${k} is required`);
};

/** One line of plain text, at most 80 characters, no control characters and no angle brackets. */
function line(field: string, v: unknown): string {
  if (typeof v !== "string") return fail(`${field} must be a string`);
  if (/[\r\n\u0085\u2028\u2029]/.test(v)) fail(`${field} must be one line`);
  if (/[\p{Cc}\p{Cf}]/u.test(v)) fail(`${field} must not contain control or invisible format characters`);
  if (/[<>]/.test(v)) fail(`${field} must not contain < or >`);
  if (hasLink(v)) fail(`${field} must not contain an email address or a link`);
  const s = v.replace(/\s+/g, " ").trim();
  if (s === "") fail(`${field} is empty`);
  if (s.length > GOAL_MAX_CHARS) fail(`${field} is longer than ${GOAL_MAX_CHARS} characters`);
  return s;
}

export function defaultProfile(): Profile {
  return {
    version: 0, role: null, industry: null, goals: [], drains: [], schedule: null, timezone: "UTC",
    review_slot: { day: "fri", time: "16:00" }, autonomy: "suggest", own_name_to_models: "mask", keyframes_to_cloud: false,
    learning_paused: false, updated_at: null,
  };
}

export function goalId(text: string, createdAt: string): string {
  return `g_${createHash("sha256").update(`${text.trim().toLowerCase()}${createdAt}`).digest("hex").slice(0, 10)}`;
}

/** Validates a partial PATCH body against the current profile. */
export function applyProfilePatch(current: Profile, body: unknown, now: number): PatchResult {
  try {
    if (!isObject(body)) return fail("the body must be a JSON object");
    for (const k of Object.keys(body)) if (!(PATCHABLE as readonly string[]).includes(k)) fail(`${k} is not a profile field you can change`);
    const at = new Date(now).toISOString();
    const next: Profile = structuredClone(current);
    let added: Goal[] = [];
    let archived: Goal[] = [];
    for (const k of ["role", "industry"] as const) {
      if (!(k in body)) continue;
      const v = body[k];
      next[k] = v === null || v === "" ? null : line(k, v);
    }
    if ("goals" in body) {
      const g = body["goals"];
      if (!Array.isArray(g)) return fail("goals must be a list");
      if (g.length > MAX_GOALS) fail(`at most ${MAX_GOALS} goals`);
      const texts = g.map((item, i) => {
        if (isObject(item)) {
          exactKeys(`goals[${i}]`, item, ["text"]);
          return line(`goals[${i}]`, item["text"]);
        }
        return line(`goals[${i}]`, item);
      });
      const lower = texts.map((t) => t.toLowerCase());
      if (new Set(lower).size !== lower.length) fail("goals repeat");
      const active = new Map(current.goals.filter((x) => x.archived_at === null).map((x) => [x.text.toLowerCase(), x]));
      next.goals = texts.map((text) => active.get(text.toLowerCase()) ?? { id: goalId(text, at), text, horizon: "90d" as const, created_at: at, archived_at: null });
      added = next.goals.filter((x) => !active.has(x.text.toLowerCase()));
      archived = [...active.values()].filter((x) => !lower.includes(x.text.toLowerCase())).map((x) => ({ ...x, archived_at: at }));
    }
    if ("drains" in body) {
      const d = body["drains"];
      if (!Array.isArray(d)) return fail("drains must be a list");
      next.drains = [...new Set(d.map((x) => oneOf("drains", x, DRAINS)))];
    }
    if ("schedule" in body) {
      const s = body["schedule"];
      if (s === null) next.schedule = null;
      else {
        if (!isObject(s)) return fail("schedule must be an object or null");
        exactKeys("schedule", s, ["days", "start", "end"]);
        if (!Array.isArray(s["days"])) return fail("schedule.days must be a list");
        const days = new Set((s["days"] as unknown[]).map((x) => oneOf("schedule.days", x, WEEKDAYS)));
        const start = s["start"];
        const end = s["end"];
        if (typeof start !== "string" || !TIME_RE.test(start) || typeof end !== "string" || !TIME_RE.test(end)) return fail("schedule.start and schedule.end must be HH:MM");
        next.schedule = { days: WEEKDAYS.filter((x) => days.has(x)), start, end };
      }
    }
    if ("timezone" in body) {
      const tz = body["timezone"];
      if (typeof tz !== "string" || !isValidTimezone(tz)) return fail("timezone must be an IANA time zone");
      next.timezone = tz;
    }
    if ("review_slot" in body) {
      const r = body["review_slot"];
      if (!isObject(r)) return fail("review_slot must be { day, time }");
      exactKeys("review_slot", r, ["day", "time"]);
      const time = r["time"];
      if (typeof time !== "string" || !TIME_RE.test(time)) return fail("review_slot.time must be HH:MM");
      next.review_slot = { day: oneOf("review_slot.day", r["day"], WEEKDAYS), time };
    }
    if ("autonomy" in body) next.autonomy = oneOf("autonomy", body["autonomy"], AUTONOMY);
    if ("own_name_to_models" in body) next.own_name_to_models = oneOf("own_name_to_models", body["own_name_to_models"], OWN_NAME);
    if ("keyframes_to_cloud" in body) {
      const v = body["keyframes_to_cloud"];
      if (typeof v !== "boolean") return fail("keyframes_to_cloud must be true or false");
      next.keyframes_to_cloud = v;
    }
    next.version = current.version + 1;
    next.updated_at = at;
    return { ok: true, profile: next, added, archived };
  } catch (err) {
    if (err instanceof Invalid) return { ok: false, message: err.message };
    throw err;
  }
}

export function userContextOf(p: Profile): UserContext {
  return sanitizeUserContext({ role: p.role, industry: p.industry, goals: p.goals.filter((g) => g.archived_at === null).map((g) => g.text) }) ?? {};
}
