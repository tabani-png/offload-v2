// The weekly sentence: model words, numbers checked by code (ADR 0003, harvested from PR #43 checkNarrative).
// v2 fix: known numbers are the values of the record's Figures (and plain numeric fields and list lengths), never
// digits harvested from strings: dates, week labels, ids and the constants inside `arithmetic` ("/ 60", "x 100")
// do not make a number known.
import type { CompleteText } from "../user-model/ports.ts";
import { userContextBlock, type UserContext } from "../understanding/context.ts";
import { hasAnyLink } from "../user-model/names.ts";
import { isFigure, r1, r2 } from "./figure.ts";
import type { WeekRecord } from "./week-record.ts";

const SKIP_KEYS = new Set(["id", "evidence", "arithmetic", "source_purged_at"]);
const NUMBER_RE = /\d+(?:\.\d+)?/g;
/** Cardinal number words, checked against the record like digits (ADR 0003: a number in words is still a number). */
const UNITS: Readonly<Record<string, number>> = {
  zero: 0, one: 1, two: 2, three: 3, four: 4, five: 5, six: 6, seven: 7, eight: 8, nine: 9, ten: 10, eleven: 11,
  twelve: 12, thirteen: 13, fourteen: 14, fifteen: 15, sixteen: 16, seventeen: 17, eighteen: 18, nineteen: 19,
};
const TENS: Readonly<Record<string, number>> = { twenty: 20, thirty: 30, forty: 40, fifty: 50, sixty: 60, seventy: 70, eighty: 80, ninety: 90 };
/** Multipliers, fractions and scales imply arithmetic the record does not hold: always refused. */
const REFUSED_WORDS = new Set([
  "half", "halves", "halved", "twice", "thrice", "double", "doubled", "doubles", "triple", "tripled", "triples",
  "quadruple", "quadrupled", "dozen", "dozens", "quarter", "quarters", "third", "thirds", "hundred", "hundreds",
  "thousand", "thousands", "million", "millions", "billion", "billions",
]);

/** Number words in a text: `{ word, value }`, value null for a refused word. `forty-two` and `forty two` are 42. */
function numberWords(text: string): Array<{ word: string; value: number | null }> {
  const out: Array<{ word: string; value: number | null }> = [];
  const tokens = text.toLowerCase().match(/[a-z]+/g) ?? [];
  for (let i = 0; i < tokens.length; i++) {
    const t = tokens[i]!;
    const next = tokens[i + 1];
    if (TENS[t] !== undefined && next !== undefined && (UNITS[next] ?? 0) >= 1 && UNITS[next]! <= 9) {
      out.push({ word: `${t} ${next}`, value: TENS[t]! + UNITS[next]! });
      i += 1;
    } else if (UNITS[t] !== undefined) out.push({ word: t, value: UNITS[t]! });
    else if (TENS[t] !== undefined) out.push({ word: t, value: TENS[t]! });
    else if (REFUSED_WORDS.has(t)) out.push({ word: t, value: null });
  }
  return out;
}
const normalize = (text: string) => text.replace(/(\d),(?=\d{3}(?:\D|$))/g, "$1");
export const MAX_SENTENCE = 300;

/** A model-written text may only use numbers that are in the record, written in digits or as cardinal words. */
export function checkNarrative(text: string, record: unknown): { ok: boolean; unknown: string[] } {
  const known = new Set<string>();
  const add = (n: number, ratio = false) => {
    const vs = [n, r1(n), r2(n), Math.round(n)];
    if (ratio) vs.push(r1(n * 100), Math.round(n * 100));
    for (const v of vs) known.add(String(Math.abs(v)));
  };
  const walk = (v: unknown, key: string) => {
    if (SKIP_KEYS.has(key)) return;
    if (isFigure(v)) add(v.value, v.unit === "ratio");
    else if (typeof v === "number") add(v);
    else if (Array.isArray(v)) {
      add(v.length);
      for (const x of v) walk(x, key);
    } else if (typeof v === "object" && v !== null) for (const [k, x] of Object.entries(v)) walk(x, k);
  };
  walk(record, "");
  const unknown = (normalize(text).match(NUMBER_RE) ?? []).filter((n) => !known.has(String(Number(n))));
  for (const w of numberWords(text)) if (w.value === null || !known.has(String(w.value))) unknown.push(w.word);
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
    "Write every number in digits, never as a word, and do not compare with other weeks.",
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
  // A link (bare host names included) or an email address is never shown or stored; the code sentence stands.
  if (sentence === "" || sentence.length > MAX_SENTENCE || hasAnyLink(sentence) || !checkNarrative(sentence, record).ok) return fallback;
  return { sentence, source: "model" };
}
