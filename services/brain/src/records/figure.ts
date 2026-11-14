// Figures (ADR 0003): every number the user model shows is computed in code and carries how it was counted.

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

export function figureId(_f: Omit<Figure, "id">): string {
  throw new Error("not implemented");
}

export function figure(
  _value: number,
  _unit: FigureUnit,
  _arithmetic: string,
  _evidence: readonly EvidenceRef[],
  _sourcePurgedAt: string | null = null,
): Figure {
  throw new Error("not implemented");
}

export function isFigure(_v: unknown): _v is Figure {
  throw new Error("not implemented");
}

/** Every figure in a record with its RFC 6901 JSON pointer, in document order. */
export function collectFigures(_record: unknown): Array<{ pointer: string; figure: Figure }> {
  throw new Error("not implemented");
}

/** A copy of the record with every figure's `source_purged_at` set and its id recomputed. Values never change. */
export function withSourcePurged<T>(_record: T, _at: string): T {
  throw new Error("not implemented");
}

export const r1 = (x: number): number => Math.round(x * 10) / 10;
export const r2 = (x: number): number => Math.round(x * 100) / 100;
export const r3 = (x: number): number => Math.round(x * 1000) / 1000;
