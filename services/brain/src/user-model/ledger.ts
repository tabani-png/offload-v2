// Task ledger (old brain/src/memory/ledger.ts): maps each induced task to a long-lived task key.
// Match order (ARCHITECTURE section 5): same signature; else same kind, app and host with masked-name Jaccard >= 0.5;
// else centroid cosine >= 0.85; else a new key. Bigger tasks claim keys first; a key is used at most once per window.
// v2 fixes: empty word sets never match by name; a matched entry takes the latest name words, centroid and days.
import { createHash } from "node:crypto";
import { dayOf } from "../records/dates.ts";
import { nameWords, taskName } from "./names.ts";
import type { DayLabel, UnderstandingWindow, WindowTask } from "./ports.ts";

export const NAME_MATCH = 0.5;
export const CENTROID_MATCH = 0.85;

export interface LedgerEntry {
  /** `k_` + 12 hex. */
  taskKey: string;
  /** sha256(signature), first 16 hex each. */
  signatures: string[];
  taskKind: string;
  appBundleId: string;
  host: string;
  nameWords: string[];
  name: string;
  centroid: number[] | null;
  firstSeenDay: DayLabel;
  lastSeenDay: DayLabel;
}

export interface LedgerResult {
  ledger: LedgerEntry[];
  /** window task id -> task key */
  keys: Map<string, string>;
}

const sha = (s: string) => createHash("sha256").update(s).digest("hex");
export const signatureHash = (signature: string) => sha(signature).slice(0, 16);

export function cosine(a: readonly number[], b: readonly number[]): number {
  if (a.length === 0 || a.length !== b.length) return 0;
  let dot = 0;
  let na = 0;
  let nb = 0;
  for (let i = 0; i < a.length; i++) {
    dot += a[i]! * b[i]!;
    na += a[i]! * a[i]!;
    nb += b[i]! * b[i]!;
  }
  return na === 0 || nb === 0 ? 0 : dot / Math.sqrt(na * nb);
}

export function jaccard(a: readonly string[], b: readonly string[]): number {
  if (a.length === 0 || b.length === 0) return 0;
  const B = new Set(b);
  const inter = a.filter((x) => B.has(x)).length;
  return inter / (a.length + b.length - inter);
}

function best<T>(items: readonly T[], score: (x: T) => number, min: number): T | undefined {
  let out: { x: T; s: number } | undefined;
  for (const x of items) {
    const s = score(x);
    if (s >= min && (out === undefined || s > out.s)) out = { x, s };
  }
  return out?.x;
}

export function resolveTaskKeys(prior: readonly LedgerEntry[], window: UnderstandingWindow): LedgerResult {
  const ledger: LedgerEntry[] = prior.map((e) => structuredClone(e)).sort((x, y) => (x.taskKey < y.taskKey ? -1 : 1));
  const keys = new Map<string, string>();
  const used = new Set<string>();
  const tasks = window.tasks.filter((t) => t.instances.length > 0).sort((x, y) => y.instances.length - x.instances.length || (x.id < y.id ? -1 : x.id > y.id ? 1 : 0));
  const claim = (t: WindowTask, e: LedgerEntry) => {
    const name = taskName(t.name, t.kind);
    const days = t.instances.map((i) => dayOf(i.start, window.timezone)).sort();
    const sig = signatureHash(t.signature);
    if (!e.signatures.includes(sig)) e.signatures.push(sig);
    e.taskKind = t.kind;
    e.appBundleId = t.appBundleId;
    e.host = t.host;
    e.name = name;
    // Words from the task's own name only: the kind-word fallback name must not make two nameless tasks match.
    e.nameWords = nameWords(t.name);
    if (t.centroid !== null) e.centroid = [...t.centroid];
    const first = days[0];
    const last = days[days.length - 1];
    if (first !== undefined && (e.firstSeenDay === "" || first < e.firstSeenDay)) e.firstSeenDay = first;
    if (last !== undefined && last > e.lastSeenDay) e.lastSeenDay = last;
    used.add(e.taskKey);
    keys.set(t.id, e.taskKey);
  };

  const pending: WindowTask[] = [];
  for (const t of tasks) {
    const sig = signatureHash(t.signature);
    const hit = ledger.find((e) => !used.has(e.taskKey) && e.signatures.includes(sig));
    if (hit === undefined) pending.push(t);
    else claim(t, hit);
  }
  for (const t of pending) {
    const free = ledger.filter((e) => !used.has(e.taskKey));
    const words = nameWords(t.name);
    let entry = best(free.filter((e) => e.taskKind === t.kind && e.appBundleId === t.appBundleId && e.host === t.host), (e) => jaccard(words, e.nameWords), NAME_MATCH);
    if (entry === undefined && t.centroid !== null) {
      const c = t.centroid;
      entry = best(free.filter((e) => e.centroid !== null), (e) => cosine(c, e.centroid!), CENTROID_MATCH);
    }
    if (entry === undefined) {
      let n = 0;
      let key = `k_${sha(`${t.kind}|${t.appBundleId}|${t.host}|${signatureHash(t.signature)}`).slice(0, 12)}`;
      while (ledger.some((e) => e.taskKey === key)) key = `k_${sha(`${key}|${++n}`).slice(0, 12)}`;
      entry = { taskKey: key, signatures: [], taskKind: t.kind, appBundleId: t.appBundleId, host: t.host, nameWords: [], name: "", centroid: null, firstSeenDay: "", lastSeenDay: "" };
      ledger.push(entry);
    }
    claim(t, entry);
  }
  ledger.sort((x, y) => (x.taskKey < y.taskKey ? -1 : 1));
  return { ledger, keys };
}
