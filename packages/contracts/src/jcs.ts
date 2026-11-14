/**
 * RFC 8785 JSON Canonicalization Scheme. The one canonicaliser (ADR 0008).
 * Strict on purpose: anything JSON cannot represent throws, so signed bytes are never ambiguous.
 * Strings and numbers use ECMAScript's JSON.stringify, which is what RFC 8785 specifies (sections 3.2.2.2, 3.2.2.3).
 */
export function jcs(value: unknown): string {
  return canon(value);
}

function canon(v: unknown): string {
  if (v === null) return "null";
  switch (typeof v) {
    case "boolean":
      return v ? "true" : "false";
    case "number":
      if (!Number.isFinite(v)) throw new TypeError("jcs: non-finite number");
      return JSON.stringify(v);
    case "string":
      if (hasLoneSurrogate(v)) throw new TypeError("jcs: lone surrogate in string");
      return JSON.stringify(v);
    case "object": {
      if (Array.isArray(v)) {
        const parts: string[] = [];
        for (let i = 0; i < v.length; i++) {
          if (!(i in v)) throw new TypeError("jcs: sparse array");
          parts.push(canon(v[i]));
        }
        return `[${parts.join(",")}]`;
      }
      const proto = Object.getPrototypeOf(v) as unknown;
      if (proto !== Object.prototype && proto !== null) throw new TypeError("jcs: only plain objects");
      const rec = v as Record<string, unknown>;
      // Default sort compares UTF-16 code units, as RFC 8785 section 3.2.3 requires.
      const keys = Object.keys(rec).sort();
      return `{${keys.map((k) => `${canon(k)}:${canon(rec[k])}`).join(",")}}`;
    }
    default:
      throw new TypeError(`jcs: unsupported value of type ${typeof v}`);
  }
}

function hasLoneSurrogate(s: string): boolean {
  for (let i = 0; i < s.length; i++) {
    const c = s.charCodeAt(i);
    if (c >= 0xd800 && c <= 0xdbff) {
      const n = s.charCodeAt(i + 1);
      if (n >= 0xdc00 && n <= 0xdfff) i++;
      else return true;
    } else if (c >= 0xdc00 && c <= 0xdfff) return true;
  }
  return false;
}
