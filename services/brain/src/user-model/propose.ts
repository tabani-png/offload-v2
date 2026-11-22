// Observations -> propositions. gum (GeneralUserModels/gum, MIT; ideas only) asks a model for confidence and decay;
// here both are computed by rule from evidence counts (ADR 0003), and the text is a template over the counts.
import { createHash } from "node:crypto";
import { r1, r3 } from "../records/figure.ts";
import type { TaskObservation } from "./observe.ts";
import type { DayLabel } from "./ports.ts";
import type { DayEvidence, Proposition, PropositionEvidence, PropositionKind } from "./types.ts";

export const MIN_REPEATS = 3;
export const MIN_SHARE = 0.05;
/** Distinct days of evidence for the full day part of the confidence score. */
export const CONFIDENT_DAYS = 10;
/** Days of evidence for full durability (gum decay 10). */
export const DURABLE_DAYS = 14;
/** Per-day evidence older than this many distinct days is dropped (the model stays small). */
export const MAX_EVIDENCE_DAYS = 180;

const clamp = (x: number, lo: number, hi: number) => Math.min(hi, Math.max(lo, x));
const r4 = (x: number) => Math.round(x * 1e4) / 1e4;

export function propositionId(key: string, version: number): string {
  return `p_${createHash("sha256").update(key).digest("hex").slice(0, 10)}_v${version}`;
}

/** 0..1 evidence score: how many days (45%), how many times (35%), how alike (20%). */
export function confidenceScore(e: Pick<PropositionEvidence, "days" | "instances" | "sameness">): number {
  const days = Math.min(1, e.days / CONFIDENT_DAYS);
  const count = 1 - Math.exp(-e.instances / 6);
  return r3(0.45 * days + 0.35 * count + 0.2 * clamp(e.sameness, 0, 1));
}
export function confidenceOf(score: number): number {
  return clamp(Math.round(1 + 9 * score), 1, 10);
}
export function decayOf(e: Pick<PropositionEvidence, "days">): number {
  return clamp(Math.round(1 + 9 * Math.min(1, e.days / DURABLE_DAYS)), 1, 10);
}
export function rateOf(kind: PropositionKind, e: PropositionEvidence): number {
  if (kind === "time_share") return r4(e.share);
  return e.days === 0 ? 0 : r1(e.instances / e.days);
}

const plural = (n: number, w: string) => `${n} ${w}${n === 1 ? "" : "s"}`;

function render(p: Pick<Proposition, "kind" | "rate"> & { evidence: PropositionEvidence }): { text: string; reasoning: string } {
  const e = p.evidence;
  const s = e.subject;
  const where = s.host === "" ? s.appName : `${s.appName} (${s.host})`;
  if (p.kind === "repeats") {
    return {
      text: `They have been doing “${s.name}” repeatedly: ${e.instances} times on ${plural(e.days, "day")} (about ${p.rate} a day, typically ${e.medianMinutes} min each) in ${where}.`,
      reasoning: `Counted ${e.instances} occurrences across ${plural(e.days, "analysed day")} (${e.dayList[0] ?? ""} to ${e.dayList[e.dayList.length - 1] ?? ""}); instances look ${Math.round(e.sameness * 100)}% alike.`,
    };
  }
  return {
    text: `“${s.name}” takes about ${Math.round(p.rate * 100)}% of their active time.`,
    reasoning: `${r1(e.minutes / 60)} h of active time on ${plural(e.days, "day")}; share measured over the latest analysed window.`,
  };
}

function trimDays(perDay: Record<DayLabel, DayEvidence>): Record<DayLabel, DayEvidence> {
  const days = Object.keys(perDay).sort();
  return Object.fromEntries(days.slice(Math.max(0, days.length - MAX_EVIDENCE_DAYS)).map((d) => [d, { ...perDay[d]! }]));
}

/** Recounts instances, days, minutes, day list and sameness from `perDay`, then rate, confidence, decay and text. */
export function finish(p: Proposition): Proposition {
  const perDay = trimDays(p.evidence.perDay);
  const dayList = Object.keys(perDay).sort();
  let instances = 0;
  let minutes = 0;
  let weighted = 0;
  let weight = 0;
  for (const d of dayList) {
    const x = perDay[d]!;
    instances += x.instances;
    minutes += x.minutes;
    if (x.sameness !== undefined) {
      weighted += x.sameness * x.instances;
      weight += x.instances;
    }
  }
  const evidence: PropositionEvidence = {
    ...p.evidence, perDay, dayList, days: dayList.length, instances, minutes: r1(minutes),
    sameness: weight === 0 ? p.evidence.sameness : r4(weighted / weight),
  };
  const rate = rateOf(p.kind, evidence);
  const score = confidenceScore(evidence);
  const { text, reasoning } = render({ kind: p.kind, rate, evidence });
  return { ...p, rate, text, confidence: confidenceOf(score), confidenceScore: score, decay: decayOf(evidence), evidence: { ...evidence, reasoning } };
}

function make(kind: PropositionKind, o: TaskObservation, now: number): Proposition {
  const key = `${kind}:${o.taskKey}`;
  return finish({
    id: propositionId(key, 1), key, kind, version: 1, revisionGroup: key, text: "", confidence: 1, confidenceScore: 0, decay: 1, rate: 0,
    evidence: {
      instances: 0, days: 0, minutes: 0, dayList: [], perDay: structuredClone(o.perDay), sameness: o.sameness, medianMinutes: o.medianMinutes,
      share: o.share, lastSeenAt: o.lastEnd, reasoning: "",
      subject: { taskKey: o.taskKey, taskKind: o.taskKind, name: o.name, appName: o.appName, host: o.host },
    },
    validAt: o.firstStart, invalidAt: null, recordedAt: now, expiredAt: null,
  });
}

/** Fresh version-1 propositions for one window. Deterministic, sorted by key. */
export function propose(observations: readonly TaskObservation[], now: number): Proposition[] {
  const out: Proposition[] = [];
  for (const o of observations) {
    if (o.instances < MIN_REPEATS) continue;
    out.push(make("repeats", o, now));
    if (o.share >= MIN_SHARE) out.push(make("time_share", o, now));
  }
  return out.sort((x, y) => (x.key < y.key ? -1 : x.key > y.key ? 1 : 0));
}
