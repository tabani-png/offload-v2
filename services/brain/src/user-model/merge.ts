// Merge a fresh window into the long-term propositions.
// gum (revise; GeneralUserModels/gum, MIT, ideas only): same key and a similar rate -> the current version gains the
// evidence (per-day counts union, fresh days win; counts, confidence and text recomputed).
// graphiti (resolve_edge_contradictions; getzep/graphiti, Apache-2.0, ideas only): a rate moved by more than
// CONTRADICTION_RATIO -> the current version ends (invalid_at = the later of its valid_at and the new valid_at,
// expired_at = now) and the next version starts in the same revision group.
// A current belief not seen for STALE_ANALYSED_DAYS analysed days ends (invalid_at = last seen). Nothing is deleted.
import { finish, propositionId } from "./propose.ts";
import type { DayLabel } from "./ports.ts";
import type { Proposition } from "./types.ts";

export { MAX_EVIDENCE_DAYS } from "./propose.ts";
export const CONTRADICTION_RATIO = 0.5;
export const STALE_ANALYSED_DAYS = 7;

export interface MergeOptions {
  now: number;
  /** Every analysed day known for the member (days with a day record), including this window's. */
  analysedDays: readonly DayLabel[];
}

const byKeyVersion = (a: Proposition, b: Proposition) => (a.key < b.key ? -1 : a.key > b.key ? 1 : a.version - b.version);

export function contradicts(cur: Proposition, fresh: Proposition): boolean {
  const base = Math.max(Math.abs(cur.rate), 1e-9);
  return Math.abs(fresh.rate - cur.rate) / base > CONTRADICTION_RATIO;
}

function revise(cur: Proposition, fresh: Proposition): Proposition {
  return {
    ...cur,
    validAt: Math.min(cur.validAt, fresh.validAt),
    evidence: {
      ...cur.evidence,
      perDay: { ...structuredClone(cur.evidence.perDay), ...structuredClone(fresh.evidence.perDay) },
      medianMinutes: fresh.evidence.medianMinutes,
      share: fresh.evidence.share,
      lastSeenAt: Math.max(cur.evidence.lastSeenAt, fresh.evidence.lastSeenAt),
      subject: { ...fresh.evidence.subject },
    },
  };
}

export function mergePropositions(prior: readonly Proposition[], fresh: readonly Proposition[], opts: MergeOptions): Proposition[] {
  const { now } = opts;
  const props = prior.map((p) => structuredClone(p));
  const touched = new Set<string>();
  // Rates are always derived from evidence (finish), never trusted from the input.
  for (const f of fresh.map((x) => finish(structuredClone(x))).sort(byKeyVersion)) {
    const versions = props.filter((p) => p.key === f.key);
    const cur = versions.find((p) => p.invalidAt === null);
    touched.add(f.key);
    if (versions.length === 0) {
      props.push(finish({ ...structuredClone(f), id: propositionId(f.key, 1), version: 1, revisionGroup: f.key, invalidAt: null, expiredAt: null, recordedAt: now }));
      continue;
    }
    if (cur !== undefined && !contradicts(finish(cur), f)) {
      props[props.indexOf(cur)] = finish(revise(cur, f));
      continue;
    }
    const latest = versions.reduce((a, b) => (b.version > a.version ? b : a));
    const version = latest.version + 1;
    if (cur !== undefined) {
      cur.invalidAt = Math.max(cur.validAt, f.validAt);
      cur.expiredAt ??= now;
    }
    props.push(finish({ ...structuredClone(f), id: propositionId(f.key, version), version, revisionGroup: latest.revisionGroup, invalidAt: null, expiredAt: null, recordedAt: now }));
  }
  const analysed = [...new Set(opts.analysedDays)].sort();
  for (const p of props) {
    if (p.invalidAt !== null || touched.has(p.key)) continue;
    const lastDay = p.evidence.dayList[p.evidence.dayList.length - 1];
    if (lastDay === undefined) continue;
    const after = analysed.filter((d) => d > lastDay).length;
    if (after < STALE_ANALYSED_DAYS) continue;
    p.invalidAt = Math.max(p.validAt, p.evidence.lastSeenAt);
    p.expiredAt = now;
  }
  return props.sort(byKeyVersion);
}
