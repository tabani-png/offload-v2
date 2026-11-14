// Figures (ADR 0003): every number the user model shows is computed in code and carries how it was counted.
import { createHash } from "node:crypto";
import { jcs } from "./jcs.ts";

export type EvidenceKind = "observation" | "episode" | "day_record" | "week_record" | "fix_estimate" | "review_answer";

export interface EvidenceRef {
  kind: EvidenceKind;
  id: string;
}

export type FigureUnit =
  | "minutes"
  | "hours"
  | "count"
  | "per_hour"
  | "percent"
  | "ratio"
  | "hours_per_week"
  | "minutes_per_week"
  | "weeks"
  | "score";

export interface Figure {
  /** `fig_` + first 16 hex of sha256(JCS(figure without id)). */
  id: string;
  value: number;
  unit: FigureUnit;
  arithmetic: string;
  evidence: EvidenceRef[];
  /** When the raw evidence passed its TTL; null while it exists. Always present. */
  source_purged_at: string | null;
}

export function figureId(f: Omit<Figure, "id">): string {
  const body = { value: f.value, unit: f.unit, arithmetic: f.arithmetic, evidence: f.evidence, source_purged_at: f.source_purged_at };
  return `fig_${createHash("sha256").update(jcs(body)).digest("hex").slice(0, 16)}`;
}

export function figure(
  value: number,
  unit: FigureUnit,
  arithmetic: string,
  evidence: readonly EvidenceRef[],
  sourcePurgedAt: string | null = null,
): Figure {
  if (!Number.isFinite(value)) throw new RangeError(`figure value must be finite (${arithmetic})`);
  const body = { value, unit, arithmetic, evidence: evidence.map((e) => ({ kind: e.kind, id: e.id })), source_purged_at: sourcePurgedAt };
  return { id: figureId(body), ...body };
}

export function isFigure(v: unknown): v is Figure {
  if (typeof v !== "object" || v === null || Array.isArray(v)) return false;
  const o = v as Record<string, unknown>;
  return typeof o["id"] === "string" && o["id"].startsWith("fig_") && typeof o["value"] === "number" && typeof o["arithmetic"] === "string" && Array.isArray(o["evidence"]);
}

const escapePointer = (k: string) => k.replaceAll("~", "~0").replaceAll("/", "~1");

/** Every figure in a record with its RFC 6901 JSON pointer, in document order. */
export function collectFigures(record: unknown): Array<{ pointer: string; figure: Figure }> {
  const out: Array<{ pointer: string; figure: Figure }> = [];
  const walk = (v: unknown, ptr: string) => {
    if (isFigure(v)) {
      out.push({ pointer: ptr, figure: v });
      return;
    }
    if (Array.isArray(v)) v.forEach((x, i) => walk(x, `${ptr}/${i}`));
    else if (typeof v === "object" && v !== null) for (const [k, x] of Object.entries(v)) walk(x, `${ptr}/${escapePointer(k)}`);
  };
  walk(record, "");
  return out;
}

/** A copy of the record with every figure's `source_purged_at` set and its id recomputed. Values never change. */
export function withSourcePurged<T>(record: T, at: string): T {
  const walk = (v: unknown): unknown => {
    if (isFigure(v)) return figure(v.value, v.unit, v.arithmetic, v.evidence, at);
    if (Array.isArray(v)) return v.map(walk);
    if (typeof v === "object" && v !== null) return Object.fromEntries(Object.entries(v).map(([k, x]) => [k, walk(x)]));
    return v;
  };
  return walk(record) as T;
}

export const r1 = (x: number): number => Math.round(x * 10) / 10;
export const r2 = (x: number): number => Math.round(x * 100) / 100;
export const r3 = (x: number): number => Math.round(x * 1000) / 1000;
