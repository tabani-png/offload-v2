// Hashes for the builder. canonicalJson is RFC 8785 JCS for the value types the builder hashes (objects, arrays,
// strings, finite numbers, booleans, null): keys sorted by UTF-16 code units, ES number form. It stands in for
// packages/contracts' JCS until W1-E lands it (DESIGN.md section 4); the outputs are the same for these inputs.
import { createHash } from "node:crypto";

export const sha256Hex = (data: string | Uint8Array): string => createHash("sha256").update(data).digest("hex");

export function canonicalJson(v: unknown): string {
  if (v === null || typeof v === "boolean" || typeof v === "string") return JSON.stringify(v);
  if (typeof v === "number") {
    if (!Number.isFinite(v)) throw new Error("canonicalJson: numbers must be finite");
    return JSON.stringify(v);
  }
  if (Array.isArray(v)) return `[${v.map(canonicalJson).join(",")}]`;
  if (typeof v === "object") {
    const o = v as Record<string, unknown>;
    const keys = Object.keys(o).filter((k) => o[k] !== undefined).sort();
    return `{${keys.map((k) => `${JSON.stringify(k)}:${canonicalJson(o[k])}`).join(",")}}`;
  }
  throw new Error(`canonicalJson: unsupported ${typeof v}`);
}

export const HEX64 = /^[0-9a-f]{64}$/;

/** artifact_sha256: over paths, types and contents (ARCHITECTURE section 8), order independent. */
export function artifactSha256(files: ReadonlyArray<{ path: string; bytes: Uint8Array }>): string {
  const entries = [...files].map((f) => ({ path: f.path, type: "file", sha256: sha256Hex(f.bytes) })).sort((a, b) => (a.path < b.path ? -1 : a.path > b.path ? 1 : 0));
  return sha256Hex(canonicalJson(entries));
}
