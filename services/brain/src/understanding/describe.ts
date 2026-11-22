// Span descriptions (DESCRIBE), rules first: verb and object from fixed vocabularies counted in the span's masked title
// and text, else a default verb by kind of work; pseudonyms from the focus `doc`, title and text; content words. The
// optional `label` route (labeler.ts, through the model router) fills a verb or object the rules did not find, and
// only with a value from the same vocabularies. Nothing here stores or logs text.
import { dayOf } from "../records/dates.ts";
import { kindOf, type WorkKind } from "../records/kinds.ts";
import type { SpanLabeler } from "./labeler.ts";
import type { Span, SpanDescription } from "./types.ts";

export const SPAN_VERBS = ["create", "send", "reply", "approve", "reject", "submit", "pay", "export", "upload", "update", "reconcile", "schedule", "search", "attend", "read", "write", "edit", "view"] as const;
export const SPAN_OBJECTS = [
  "invoice", "bill", "order", "ticket", "customer", "contact", "deal", "lead", "report", "payment", "expense", "receipt", "shipment",
  "timesheet", "contract", "quote", "candidate", "claim", "booking", "refund", "statement", "document", "task", "project",
] as const;
export type SpanVerb = (typeof SPAN_VERBS)[number];
export type SpanObject = (typeof SPAN_OBJECTS)[number];

/** Screen words that name a verb. Earlier verbs win a tie. */
const VERB_WORDS: Readonly<Partial<Record<SpanVerb, readonly string[]>>> = {
  create: ["create", "new", "add"],
  send: ["send"],
  reply: ["reply", "respond"],
  approve: ["approve"],
  reject: ["reject", "decline"],
  submit: ["submit"],
  pay: ["pay"],
  export: ["export", "download"],
  upload: ["upload", "import", "attach"],
  update: ["update"],
  reconcile: ["reconcile"],
  schedule: ["schedule"],
  search: ["search"],
};
const WORD_VERB = new Map<string, SpanVerb>();
for (const v of SPAN_VERBS) for (const w of VERB_WORDS[v] ?? []) WORD_VERB.set(w, v);
const WORD_OBJECT = new Map<string, SpanObject>();
for (const o of SPAN_OBJECTS) {
  WORD_OBJECT.set(o, o);
  WORD_OBJECT.set(`${o}s`, o);
}

const DEFAULT_VERB: Readonly<Record<WorkKind, SpanVerb>> = { email: "read", chat: "read", meeting: "attend", code: "write", sheet: "edit", docs: "edit", browse: "view", other: "view" };

const PSEUDONYM_RE = /<(?:doc|person|email|phone):h_[0-9a-f]{16}>/g;
const TOKEN_RE = /<[^<>]*>/g;
const STOP = new Set(
  ("the and for with from into onto this that these those are was were has have had you your our ours their them they its not but all any can " +
    "will just than then there here what when where which who how why out off per via com www http https net org").split(" "),
);
/** How many content words describe one span (most frequent first). */
export const MAX_WORDS = 48;

/** Lowercase words of 3+ letters. A token with a digit, `_`, `@`, `/` or `.` (ids, amounts, hosts, pseudonym
 * fragments) is never a word. */
export function wordsOf(text: string): string[] {
  const out: string[] = [];
  for (const raw of text.replace(TOKEN_RE, " ").split(/\s+/)) {
    if (raw === "" || /[\p{N}_@/.\\]/u.test(raw)) continue;
    for (const part of raw.normalize("NFKC").toLowerCase().split(/[^\p{L}]+/u)) {
      if (part.length >= 3 && !STOP.has(part)) out.push(part);
    }
  }
  return out;
}

function counts(words: readonly string[]): Map<string, number> {
  const m = new Map<string, number>();
  for (const w of words) m.set(w, (m.get(w) ?? 0) + 1);
  return m;
}

function pick<T extends string>(order: readonly T[], tally: ReadonlyMap<T, number>): T | null {
  let best: T | null = null;
  for (const v of order) if ((tally.get(v) ?? 0) > 0 && (best === null || tally.get(v)! > tally.get(best)!)) best = v;
  return best;
}

const surfaceWords = (d: Pick<SpanDescription, "appName" | "host" | "standIn" | "cued">): string[] =>
  wordsOf(`${d.standIn && !d.cued ? "" : d.appName} ${d.host.replace(/\./g, " ")}`);

/** The embedded text: surface words, verb, object and content words. Letters only. */
export function descriptionText(d: Pick<SpanDescription, "appName" | "host" | "standIn" | "cued" | "verb" | "object" | "words">): string {
  return [...surfaceWords(d), d.verb, d.object, ...d.words].filter((w) => w !== "").join(" ");
}

export function describeSpan(span: Span, timezone: string): SpanDescription {
  const all = [span.title, ...span.texts];
  const words = all.flatMap(wordsOf);
  const tally = counts(words);
  const verbTally = new Map<SpanVerb, number>();
  const objectTally = new Map<SpanObject, number>();
  for (const [w, n] of tally) {
    const v = WORD_VERB.get(w);
    if (v !== undefined) verbTally.set(v, (verbTally.get(v) ?? 0) + n);
    const o = WORD_OBJECT.get(w);
    if (o !== undefined) objectTally.set(o, (objectTally.get(o) ?? 0) + n);
  }
  const verb = pick(SPAN_VERBS, verbTally);
  const object = pick(SPAN_OBJECTS, objectTally);
  const content = [...tally.entries()].sort((a, b) => b[1] - a[1] || (a[0] < b[0] ? -1 : 1)).slice(0, MAX_WORDS).map(([w]) => w);
  const pseudonyms = new Set<string>(span.docs);
  for (const t of all) for (const m of t.match(PSEUDONYM_RE) ?? []) pseudonyms.add(m);
  const sorted = [...pseudonyms].sort();
  const d: SpanDescription = {
    spanId: span.id,
    day: dayOf(span.start, timezone),
    start: span.start,
    end: span.end,
    activeMs: span.activeMs,
    appBundleId: span.appBundleId,
    appName: span.appName,
    host: span.host,
    verb: verb ?? DEFAULT_VERB[kindOf(span)],
    object: object ?? "",
    pseudonyms: sorted,
    docs: sorted.filter((p) => p.startsWith("<doc:")),
    words: content,
    titleWords: [...new Set(wordsOf(span.title))],
    joinable: !(span.standIn && !span.cued && content.length === 0),
    standIn: span.standIn,
    cued: span.cued,
    verbFrom: verb === null ? "default" : "text",
    objectFrom: object === null ? "none" : "text",
    text: "",
    observationIds: span.observationIds,
  };
  d.text = descriptionText(d);
  return d;
}

const isVerb = (v: unknown): v is SpanVerb => typeof v === "string" && (SPAN_VERBS as readonly string[]).includes(v);
const isObject = (v: unknown): v is SpanObject => typeof v === "string" && (SPAN_OBJECTS as readonly string[]).includes(v);

/** Describes every span; with a labeler, one call asks for the verbs and objects the rules did not find. A labeler
 * failure leaves the rules' description (labels are optional). */
export async function describeSpans(spans: readonly Span[], timezone: string, labeler?: SpanLabeler): Promise<SpanDescription[]> {
  const out = spans.map((s) => describeSpan(s, timezone));
  if (labeler === undefined) return out;
  const need = out.filter((d) => d.joinable && d.words.length > 0 && (d.verbFrom === "default" || d.objectFrom === "none"));
  if (need.length === 0) return out;
  let labels: Map<string, { verb?: string; object?: string }>;
  try {
    labels = await labeler.label(need.map((d) => ({ span_id: d.spanId, text: [...surfaceWords(d), ...d.words].join(" ") })));
  } catch {
    // The label route is optional: a refused, failed or over-budget call leaves the rules' description.
    return out;
  }
  for (const d of need) {
    const l = labels.get(d.spanId);
    if (l === undefined) continue;
    if (d.verbFrom === "default" && isVerb(l.verb)) {
      d.verb = l.verb;
      d.verbFrom = "label";
    }
    if (d.objectFrom === "none" && isObject(l.object)) {
      d.object = l.object;
      d.objectFrom = "label";
    }
    d.text = descriptionText(d);
  }
  return out;
}
