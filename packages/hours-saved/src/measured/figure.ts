// Figure (API.md, ADR 0003): every number with its arithmetic and evidence. id = fig_ + first 16 hex of
// sha256(JCS(figure without id)). canonicalJson is RFC 8785 JCS for these value types (strings, finite numbers, null,
// arrays, objects); packages/contracts' JCS replaces it when W1-E lands.
import { createHash } from "node:crypto";

export interface Evidence {
  kind: string;
  id: string;
}

export interface Figure {
  id: string;
  value: number | null;
  unit: string;
  arithmetic: string;
  evidence: Evidence[];
  /** Required and nullable: when the raw evidence passed its TTL (RFC 3339). */
  source_purged_at: string | null;
}

export function canonicalJson(v: unknown): string {
  if (v === null || typeof v === "string" || typeof v === "boolean") return JSON.stringify(v);
  if (typeof v === "number") {
    if (!Number.isFinite(v)) throw new Error("canonicalJson: numbers must be finite");
    return JSON.stringify(v);
  }
  if (Array.isArray(v)) return `[${v.map(canonicalJson).join(",")}]`;
  if (typeof v === "object") {
    const o = v as Record<string, unknown>;
    return `{${Object.keys(o)
      .filter((k) => o[k] !== undefined)
      .sort()
      .map((k) => `${JSON.stringify(k)}:${canonicalJson(o[k])}`)
      .join(",")}}`;
  }
  throw new Error(`canonicalJson: unsupported ${typeof v}`);
}

export function figure(f: Omit<Figure, "id">): Figure {
  const body = { value: f.value, unit: f.unit, arithmetic: f.arithmetic, evidence: f.evidence, source_purged_at: f.source_purged_at };
  return { id: `fig_${createHash("sha256").update(canonicalJson(body)).digest("hex").slice(0, 16)}`, ...body };
}
