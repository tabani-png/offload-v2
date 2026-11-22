// RFC 8785 JSON Canonicalization Scheme for the JSON values the brain hashes (figure ids). Local stand-in until
// packages/contracts exports its JCS (W1-E, m1-02); see slices/p43a-user-model-core/DESIGN.md section 4.
// Numbers use the ECMAScript Number-to-string rule (what JSON.stringify does); keys sort by UTF-16 code units.

export function jcs(value: unknown): string {
  if (value === null) return "null";
  switch (typeof value) {
    case "boolean":
      return value ? "true" : "false";
    case "number":
      if (!Number.isFinite(value)) throw new TypeError("JCS: numbers must be finite");
      return JSON.stringify(value);
    case "string":
      return JSON.stringify(value);
    case "object": {
      if (Array.isArray(value)) return `[${value.map(jcs).join(",")}]`;
      const o = value as Record<string, unknown>;
      const keys = Object.keys(o).filter((k) => o[k] !== undefined).sort();
      return `{${keys.map((k) => `${JSON.stringify(k)}:${jcs(o[k])}`).join(",")}}`;
    }
    default:
      throw new TypeError(`JCS: cannot encode ${typeof value}`);
  }
}
