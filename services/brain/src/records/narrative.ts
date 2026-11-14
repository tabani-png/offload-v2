// The weekly sentence: model words, numbers checked by code (ADR 0003, harvested from PR #43 checkNarrative).
// v2 fix: numbers are harvested from numeric values and from text that can hold numbers (arithmetic, labels), never
// from ids, keys or hashes, so a digit inside `k_9a…` or `fig_77…` does not make "9 hours" pass.
import type { CompleteText } from "../user-model/ports.ts";
import { userContextBlock, type UserContext } from "../understanding/context.ts";
import { r1, r2 } from "./figure.ts";
import type { WeekRecord } from "./week-record.ts";

const SKIP_KEYS = new Set(["id", "evidence", "task_key", "subject_key", "goal_id", "episode_ids"]);
const ID_RE = /^(?:[a-z]{1,3}_[A-Za-z0-9_]+|[0-9a-f]{16,})$/;
const NUMBER_RE = /\d+(?:\.\d+)?/g;
const normalize = (text: string) => text.replace(/(\d),(?=\d{3}(?:\D|$))/g, "$1");
export const MAX_SENTENCE = 300;

/** A model-written text may only use numbers that are in the record. */
export function checkNarrative(text: string, record: unknown): { ok: boolean; unknown: string[] } {
  const known = new Set<string>();
  const add = (n: number) => {
    for (const v of [n, Math.abs(n), r1(n), r2(n), Math.round(n), r1(n * 100), Math.round(n * 100), Math.abs(r1(n)), Math.abs(Math.round(n))]) known.add(String(v));
  };
  const walk = (v: unknown, key: string) => {
    if (SKIP_KEYS.has(key)) return;
    if (typeof v === "number") add(v);
    else if (typeof v === "string") {
      if (ID_RE.test(v)) return;
      for (const m of normalize(v).match(NUMBER_RE) ?? []) add(Number(m));
    } else if (Array.isArray(v)) {
      add(v.length);
      for (const x of v) walk(x, key);
    } else if (typeof v === "object" && v !== null) for (const [k, x] of Object.entries(v)) walk(x, k);
  };
  walk(record, "");
  const unknown = (normalize(text).match(NUMBER_RE) ?? []).filter((n) => !known.has(String(Number(n))));
  return { ok: unknown.length === 0, unknown };
}

/** The code sentence for a week (used when no model sentence passes the check). Every number is a record value. */
export function weekSentence(record: WeekRecord): string {
  return `You worked ${record.hours.total.value} h this week: ${record.focus.minutes.value} min in focus blocks and ${record.focus.meeting_hours.value} h in meetings.`;
}

/** The prompt for the weekly sentence. Goals appear only inside the <user_context> block. */
export function weekNarrativePrompt(record: WeekRecord, user: UserContext | undefined): string {
  const tasks = record.tasks.slice(0, 5).map((t) => {
    const vs = t.vs_baseline === null ? "" : `, ${t.vs_baseline.value}% vs the usual week`;
    return `task: ${t.name}: ${t.minutes.value} min, ${t.status}${vs}`;
  });
  return [
    "Write one short sentence for this person's weekly review, in plain words, addressed to them.",
    "Use only numbers that appear in the week record below. Do not compute or round new numbers.",
    userContextBlock(user),
    "<week_record>",
    `active hours: ${record.hours.total.value}`,
    `focus minutes: ${record.focus.minutes.value}`,
    `meeting hours: ${record.focus.meeting_hours.value}`,
    ...tasks,
    "</week_record>",
  ]
    .filter((l) => l !== "")
    .join("\n");
}

export async function writeWeekSentence(
  record: WeekRecord,
  user: UserContext | undefined,
  complete: CompleteText | null,
): Promise<{ sentence: string; source: "model" | "code" }> {
  const fallback = { sentence: weekSentence(record), source: "code" as const };
  if (complete === null) return fallback;
  let reply: string;
  try {
    reply = await complete(weekNarrativePrompt(record, user));
  } catch {
    // The model is optional; the code sentence stands.
    return fallback;
  }
  const sentence = reply.trim().split("\n")[0]?.trim() ?? "";
  if (sentence === "" || sentence.length > MAX_SENTENCE || !checkNarrative(sentence, record).ok) return fallback;
  return { sentence, source: "model" };
}
