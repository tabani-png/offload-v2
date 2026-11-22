// Task induction (INDUCE), deterministic. Written fresh after old brain/src/understanding/induce.ts.
//  1. Steps: a joinable span joins the step with its exact app|host|verb|object key, else the best step on the same
//     surface whose centroid has cosine >= 0.7 with it, else starts a new step. A stand-in span without a cue or an
//     object has no informative key and joins by embedding only.
//  2. Tasks: connected components of steps linked by a shared item pseudonym (`doc` at any distance in time, a person,
//     email or phone within 20 min; a pseudonym on more than 12 spans is a container, not an item) or by a reliable
//     transition (B starts within 2 min of A ending, at least twice and on at least half of A's spans).
//  3. Instances: a task's spans in time order split on a new day, a gap over 10 min, a step already in the instance
//     coming back with a disjoint `doc`, or the instance's first step recurring after another step (the loop).
import { createHash } from "node:crypto";
import { kindOf } from "../records/kinds.ts";
import type { WindowInstance, WindowTask } from "../user-model/ports.ts";
import { cosine } from "./embed.ts";
import { uuidFrom } from "./ids.ts";
import type { SpanDescription } from "./types.ts";

export interface InduceOptions {
  /** Cosine needed to join a step by embedding. */
  assignThreshold: number;
  /** A gap longer than this starts a new instance. */
  instanceGapMs: number;
  /** Person, email and phone pseudonyms link steps only within this gap. */
  linkGapMs: number;
  /** A pseudonym on more spans than this names a container, not an item. */
  itemMaxSpans: number;
  transitionGapMs: number;
  transitionMinCount: number;
  transitionMinShare: number;
}

export const INDUCE: Readonly<InduceOptions> = {
  assignThreshold: 0.7, instanceGapMs: 10 * 60_000, linkGapMs: 20 * 60_000, itemMaxSpans: 12, transitionGapMs: 2 * 60_000,
  transitionMinCount: 2, transitionMinShare: 0.5,
};

interface Step {
  index: number;
  key: string;
  surface: string;
  members: SpanDescription[];
  sum: number[] | null;
}

const surfaceOf = (d: SpanDescription) => `${d.appBundleId}|${d.host}`;
const keyOf = (d: SpanDescription) => `${surfaceOf(d)}|${d.verb}|${d.object}`;
/** A key says "same work" only when it names an object or a verb read on screen, on a surface something named. A
 * default verb with no object says only "same app", and a stand-in without a cue says nothing: those spans join by
 * embedding (or a shared pseudonym) only, so unrelated recordings never merge on a generic key. */
const informative = (d: SpanDescription) => (d.object !== "" || d.verbFrom !== "default") && !(d.standIn && !d.cued);
const byStart = (a: SpanDescription, b: SpanDescription) => a.start - b.start || (a.spanId < b.spanId ? -1 : 1);

function addVec(step: Step, v: readonly number[] | undefined): void {
  if (v === undefined) return;
  if (step.sum === null) step.sum = [...v];
  else for (let i = 0; i < v.length; i++) step.sum[i]! += v[i]!;
}

function buildSteps(descs: readonly SpanDescription[], vectors: ReadonlyMap<string, readonly number[]>, opts: InduceOptions): { steps: Step[]; stepOf: Map<string, Step> } {
  const steps: Step[] = [];
  const byKey = new Map<string, Step>();
  const stepOf = new Map<string, Step>();
  for (const d of descs) {
    const v = vectors.get(d.spanId);
    let step = informative(d) ? byKey.get(keyOf(d)) : undefined;
    if (step === undefined && v !== undefined) {
      let best: { s: Step; c: number } | null = null;
      for (const s of steps) {
        if (s.surface !== surfaceOf(d) || s.sum === null) continue;
        const c = cosine(v, s.sum);
        if (c >= opts.assignThreshold && (best === null || c > best.c)) best = { s, c };
      }
      step = best?.s;
    }
    if (step === undefined) {
      step = { index: steps.length, key: keyOf(d), surface: surfaceOf(d), members: [], sum: null };
      steps.push(step);
      if (informative(d)) byKey.set(step.key, step);
    }
    step.members.push(d);
    addVec(step, v);
    stepOf.set(d.spanId, step);
  }
  return { steps, stepOf };
}

class UnionFind {
  private readonly parent: number[];
  constructor(n: number) {
    this.parent = Array.from({ length: n }, (_, i) => i);
  }
  find(i: number): number {
    while (this.parent[i] !== i) {
      this.parent[i] = this.parent[this.parent[i]!]!;
      i = this.parent[i]!;
    }
    return i;
  }
  union(a: number, b: number): void {
    const ra = this.find(a);
    const rb = this.find(b);
    if (ra !== rb) this.parent[Math.max(ra, rb)] = Math.min(ra, rb);
  }
}

function link(descs: readonly SpanDescription[], steps: readonly Step[], stepOf: ReadonlyMap<string, Step>, opts: InduceOptions): UnionFind {
  const uf = new UnionFind(steps.length);
  // Shared item pseudonyms.
  const holders = new Map<string, SpanDescription[]>();
  for (const d of descs) for (const p of d.pseudonyms) holders.set(p, [...(holders.get(p) ?? []), d]);
  for (const [p, list] of holders) {
    if (list.length < 2 || list.length > opts.itemMaxSpans) continue;
    const isDoc = p.startsWith("<doc:");
    for (let i = 0; i < list.length; i++) {
      for (let j = i + 1; j < list.length; j++) {
        const a = list[i]!;
        const b = list[j]!;
        const gap = Math.max(0, Math.max(a.start, b.start) - Math.min(a.end, b.end));
        if (isDoc || gap <= opts.linkGapMs) uf.union(stepOf.get(a.spanId)!.index, stepOf.get(b.spanId)!.index);
      }
    }
  }
  // Reliable transitions between consecutive spans of one day.
  const count = new Map<string, number>();
  for (let i = 1; i < descs.length; i++) {
    const a = descs[i - 1]!;
    const b = descs[i]!;
    if (a.day !== b.day || b.start - a.end > opts.transitionGapMs || b.start < a.end) continue;
    const sa = stepOf.get(a.spanId)!;
    const sb = stepOf.get(b.spanId)!;
    if (sa === sb) continue;
    const k = `${sa.index}>${sb.index}`;
    count.set(k, (count.get(k) ?? 0) + 1);
  }
  for (const [k, n] of count) {
    const [a, b] = k.split(">").map(Number) as [number, number];
    if (n >= opts.transitionMinCount && n / steps[a]!.members.length >= opts.transitionMinShare) uf.union(a, b);
  }
  return uf;
}

interface Building {
  members: SpanDescription[];
  steps: Step[];
  docsByStep: Map<Step, Set<string>>;
}

function splitInstances(members: readonly SpanDescription[], stepOf: ReadonlyMap<string, Step>, opts: InduceOptions): Building[] {
  const out: Building[] = [];
  let cur: Building | null = null;
  for (const d of members) {
    const step = stepOf.get(d.spanId)!;
    let split = cur === null;
    if (cur !== null) {
      const prev = cur.members[cur.members.length - 1]!;
      const first = cur.steps[0]!;
      const seen = cur.docsByStep.get(step);
      if (d.day !== prev.day) split = true;
      else if (d.start - prev.end > opts.instanceGapMs) split = true;
      else if (seen !== undefined && seen.size > 0 && d.docs.length > 0 && !d.docs.some((x) => seen.has(x))) split = true;
      else if (step === first && cur.steps.some((s) => s !== first)) split = true;
    }
    if (split) {
      cur = { members: [], steps: [], docsByStep: new Map() };
      out.push(cur);
    }
    const c = cur!;
    c.members.push(d);
    if (!c.steps.includes(step)) c.steps.push(step);
    const docs = c.docsByStep.get(step) ?? new Set<string>();
    for (const x of d.docs) docs.add(x);
    c.docsByStep.set(step, docs);
  }
  return out;
}

function jaccard<T>(a: ReadonlySet<T>, b: ReadonlySet<T>): number {
  let inter = 0;
  for (const x of a) if (b.has(x)) inter++;
  const union = a.size + b.size - inter;
  return union === 0 ? 0 : inter / union;
}

function normalize(v: number[]): number[] {
  const n = Math.sqrt(v.reduce((s, x) => s + x * x, 0));
  return n === 0 ? v : v.map((x) => x / n);
}

const cap = (s: string) => (s === "" ? s : s[0]!.toUpperCase() + s.slice(1));

function toTask(instances: readonly Building[], vectors: ReadonlyMap<string, readonly number[]>): WindowTask {
  const steps = [...new Set(instances.flatMap((i) => i.steps))];
  // The primary step starts the most instances; then more active time; then the lower key.
  const starts = new Map<Step, number>();
  for (const i of instances) starts.set(i.steps[0]!, (starts.get(i.steps[0]!) ?? 0) + 1);
  const active = (s: Step) => s.members.reduce((n, m) => n + m.activeMs, 0);
  const primary = [...steps].sort((a, b) => (starts.get(b) ?? 0) - (starts.get(a) ?? 0) || active(b) - active(a) || (a.key < b.key ? -1 : 1))[0]!;
  const lead = primary.members[0]!;
  const signature = [...new Set(steps.map((s) => s.key))].sort().join("+");
  // Names use the verb, object, app and masked title only: never words read from text snapshots (C1 text stays in
  // understanding; the name is stored in the ledger and episodes).
  const skip = new Set([lead.verb, ...lead.appName.toLowerCase().split(/[^\p{L}]+/u)]);
  const noun = lead.object !== "" ? lead.object : lead.titleWords.filter((w) => !skip.has(w)).slice(0, 2).join(" ");
  const where = lead.standIn && !lead.cued ? " on screen" : ` in ${lead.appName}`;
  const all = instances.flatMap((i) => i.members);
  const vecs = all.map((m) => vectors.get(m.spanId)).filter((v): v is readonly number[] => v !== undefined);
  let centroid: number[] | null = null;
  if (vecs.length > 0) {
    const sum = new Array<number>(vecs[0]!.length).fill(0);
    for (const v of vecs) for (let i = 0; i < v.length; i++) sum[i]! += v[i]!;
    centroid = normalize(sum);
  }
  const stepSet = new Set(steps);
  const sameness = instances.reduce((s, i) => s + jaccard(new Set(i.steps), stepSet), 0) / instances.length;
  const windowInstances: WindowInstance[] = instances.map((i) => ({
    id: uuidFrom("instance", i.members[0]!.spanId),
    start: Math.min(...i.members.map((m) => m.start)),
    end: Math.max(...i.members.map((m) => m.end)),
    activeSeconds: Math.round(i.members.reduce((n, m) => n + m.activeMs, 0) / 1000),
    spanIds: i.members.map((m) => m.spanId),
    observationIds: [...new Set(i.members.flatMap((m) => m.observationIds))],
  }));
  return {
    id: `t_${createHash("sha256").update(`${signature}\u0000${all[0]!.spanId}`).digest("hex").slice(0, 12)}`,
    signature,
    kind: `${kindOf(lead)}.${lead.verb}${lead.object === "" ? "" : `-${lead.object}`}`,
    name: `${[cap(lead.verb), noun].filter((x) => x !== "").join(" ")}${where}`,
    appBundleId: lead.appBundleId,
    appName: lead.appName,
    host: lead.host,
    centroid,
    sameness: Math.round(sameness * 1000) / 1000,
    instances: windowInstances,
  };
}

export function induceTasks(descs: readonly SpanDescription[], vectors: ReadonlyMap<string, readonly number[]>, _timezone: string, opts: InduceOptions = INDUCE): WindowTask[] {
  const joinable = descs.filter((d) => d.joinable).sort(byStart);
  if (joinable.length === 0) return [];
  const { steps, stepOf } = buildSteps(joinable, vectors, opts);
  const uf = link(joinable, steps, stepOf, opts);
  const groups = new Map<number, SpanDescription[]>();
  for (const d of joinable) {
    const root = uf.find(stepOf.get(d.spanId)!.index);
    groups.set(root, [...(groups.get(root) ?? []), d]);
  }
  const tasks = [...groups.values()].map((members) => toTask(splitInstances(members, stepOf, opts), vectors));
  return tasks.sort((a, b) => a.instances[0]!.start - b.instances[0]!.start || (a.id < b.id ? -1 : 1));
}
