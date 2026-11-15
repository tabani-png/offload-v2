#!/usr/bin/env bun
/**
 * Swift contract emitter (ADR 0008, ADR 0024). Dependency free (no quicktype): reads
 * packages/contracts/schemas/*.schema.json and writes apps/mac/Sources/OffloadContracts/Generated/*.swift.
 *
 *   bun packages/contracts/scripts/gen-swift.ts            write the committed files
 *   bun packages/contracts/scripts/gen-swift.ts --out DIR  write into DIR instead (the Swift test M302 "generated
 *                                                          Swift types are fresh" runs this and compares bytes)
 *
 * What it emits, for the JSON Schema subset the contracts use:
 *  - object with `properties` and `additionalProperties: false` -> a Codable struct whose decoder rejects unknown keys,
 *    checks required keys, `const`, `enum`, `pattern`, `minLength`/`maxLength` (UTF-16 length, the stricter of the two
 *    counts API.md names), `minimum`/`maximum` and `minItems`/`maxItems`;
 *  - string `enum` -> a closed Swift enum;
 *  - `oneOf` of objects that share a `const` discriminator (`kind`) -> an enum with one case per object;
 *  - `anyOf: [T, null]` -> an optional that is still a required key.
 * `if`/`then` clauses are not emitted; the rule they state (`import_id` with `source = import`) is checked by the server.
 * Output is a pure function of the schemas and exclusions.builtin.json, so it can be committed and diffed.
 */
import { mkdirSync, readFileSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const repo = resolve(here, "../../..");
const SCHEMA_DIR = join(repo, "packages/contracts/schemas");
const EXCLUSIONS = join(repo, "packages/masking/src/exclusions.builtin.json");
const DEFAULT_OUT = join(repo, "apps/mac/Sources/OffloadContracts/Generated");

/** Roots in dependency order: shapes that other schemas repeat come first so their types keep the short names. */
const ORDER = ["observation", "notice-ack", "review-event", "step-result", "keyframe-meta", "figure", "ingest-receipt", "error-envelope", "ingest-envelope"];

// biome-ignore lint/suspicious/noExplicitAny: JSON Schema is open-ended input.
type Schema = any;

const KEYWORDS = new Set([
  "associatedtype", "class", "deinit", "enum", "extension", "fileprivate", "func", "import", "init", "inout", "internal", "let",
  "open", "operator", "private", "precedencegroup", "protocol", "public", "rethrows", "static", "struct", "subscript", "typealias",
  "var", "break", "case", "catch", "continue", "default", "defer", "do", "else", "fallthrough", "for", "guard", "if", "in",
  "repeat", "return", "throw", "switch", "where", "while", "Any", "as", "false", "is", "nil", "self", "Self", "super", "throws",
  "true", "try", "Type", "Protocol",
]);

const words = (s: string): string[] => s.split(/[^A-Za-z0-9]+/).filter(Boolean);
const pascal = (s: string): string => words(s).map((w) => w[0]!.toUpperCase() + w.slice(1)).join("");
const camel = (s: string): string => {
  const p = pascal(s);
  return p[0]!.toLowerCase() + p.slice(1);
};
const esc = (name: string): string => (KEYWORDS.has(name) ? `\`${name}\`` : name);
const q = (s: string): string => JSON.stringify(s);
/** A Swift raw string literal for a regex or text: #"..."# never needs escapes unless the text holds "# . */
const raw = (s: string): string => {
  if (s.includes('"#')) throw new Error(`cannot emit raw string for ${s}`);
  return `#"${s}"#`;
};

/** Structural key of a schema: the root's `$schema` and `$id` do not count, so a repeated shape dedupes. */
const keyOf = (schema: Schema): string => JSON.stringify(schema, (k, v) => (k === "$schema" || k === "$id" ? undefined : v));

interface Prop {
  json: string;
  swift: string;
  type: string;
  required: boolean;
  nullable: boolean;
  schema: Schema;
  constValue?: string | number;
}

class Emitter {
  /** schema key -> Swift type name, for structural dedupe. */
  private byKey = new Map<string, string>();
  private names = new Set<string>();
  /** Chunks emitted for the root currently being processed. */
  chunks: string[] = [];
  /** The root type being processed: nested types are named from it. */
  private rootName = "";

  private unique(base: string): string {
    let name = base;
    for (let i = 2; this.names.has(name); i++) name = `${base}${i}`;
    this.names.add(name);
    return name;
  }

  /** The Swift type for `schema`, emitting declarations as needed. `prefix` + `hint` name a new type. */
  type(schema: Schema, prefix: string, hint: string): { type: string; nullable: boolean } {
    if (schema.anyOf) {
      const parts = schema.anyOf as Schema[];
      const nonNull = parts.filter((p) => p.type !== "null");
      if (nonNull.length === 1 && parts.length === 2) return { type: this.type(nonNull[0], prefix, hint).type, nullable: true };
      throw new Error(`unsupported anyOf at ${prefix}${hint}`);
    }
    if (schema.oneOf) return { type: this.union(schema, prefix, hint), nullable: false };
    if (schema.enum) return { type: this.enumType(schema, prefix, hint), nullable: false };
    switch (schema.type) {
      case "string":
        return { type: "String", nullable: false };
      case "integer":
        return { type: "Int", nullable: false };
      case "number":
        return { type: "Double", nullable: false };
      case "boolean":
        return { type: "Bool", nullable: false };
      case "array": {
        const item = this.type(schema.items, prefix, `${hint}Item`);
        return { type: `[${item.type}]`, nullable: false };
      }
      case "object":
        return { type: this.struct(schema, prefix, hint), nullable: false };
      default:
        throw new Error(`unsupported schema at ${prefix}${hint}: ${JSON.stringify(schema).slice(0, 80)}`);
    }
  }

  private enumType(schema: Schema, prefix: string, hint: string): string {
    const key = JSON.stringify({ enum: schema.enum });
    const known = this.byKey.get(key);
    if (known) return known;
    const name = this.unique(`${prefix}${pascal(hint)}`);
    this.byKey.set(key, name);
    const cases = (schema.enum as string[]).map((v) => `    case ${esc(camel(v))} = ${q(v)}`).join("\n");
    this.chunks.push(`public enum ${name}: String, Codable, CaseIterable, Sendable {\n${cases}\n}\n`);
    return name;
  }

  /** Checks for a decoded value, as Swift statements. */
  private checks(expr: string, schema: Schema, field: string, depth = 0): string[] {
    const out: string[] = [];
    if (schema.anyOf) return this.checks(expr, schema.anyOf.find((p: Schema) => p.type !== "null"), field, depth);
    if (schema.enum || schema.oneOf) return out;
    switch (schema.type) {
      case "string": {
        if (schema.minLength !== undefined || schema.maxLength !== undefined) {
          out.push(`try Check.length(${expr}, min: ${schema.minLength ?? "nil"}, max: ${schema.maxLength ?? "nil"}, field: ${q(field)})`);
        }
        if (schema.pattern !== undefined) out.push(`try Check.pattern(${expr}, ${raw(schema.pattern)}, field: ${q(field)})`);
        break;
      }
      case "integer":
      case "number": {
        if (schema.minimum !== undefined || schema.maximum !== undefined) {
          out.push(`try Check.range(Double(${expr}), min: ${schema.minimum ?? "nil"}, max: ${schema.maximum ?? "nil"}, field: ${q(field)})`);
        }
        break;
      }
      case "array": {
        if (schema.minItems !== undefined || schema.maxItems !== undefined) {
          out.push(`try Check.count(${expr}.count, min: ${schema.minItems ?? "nil"}, max: ${schema.maxItems ?? "nil"}, field: ${q(field)})`);
        }
        const inner = this.checks(`e${depth}`, schema.items, `${field}[]`, depth + 1);
        if (inner.length > 0) out.push(`for e${depth} in ${expr} {`, ...inner.map((l) => `    ${l}`), "}");
        break;
      }
      default:
        break;
    }
    return out;
  }

  private props(schema: Schema, prefix: string): Prop[] {
    const required = new Set<string>(schema.required ?? []);
    const out: Prop[] = [];
    for (const [json, p] of Object.entries<Schema>(schema.properties ?? {})) {
      if (p.const !== undefined) {
        out.push({ json, swift: esc(camel(json)), type: "", required: required.has(json), nullable: false, schema: p, constValue: p.const });
        continue;
      }
      const t = this.type(p, prefix, json);
      out.push({ json, swift: esc(camel(json)), type: t.type, required: required.has(json), nullable: t.nullable, schema: p });
    }
    return out;
  }

  /** A struct. `prefix` + `hint` is its name; the struct's own children are named from that name. */
  private struct(schema: Schema, prefix: string, hint: string, forcedName?: string): string {
    if (schema.additionalProperties !== false) throw new Error(`${prefix}${hint}: additionalProperties must be false`);
    const key = keyOf(schema);
    const known = this.byKey.get(key);
    if (known) return known;
    const name = forcedName ?? this.unique(`${prefix}${pascal(hint)}`);
    this.byKey.set(key, name);
    const props = this.props(schema, this.rootName);
    this.chunks.push(this.emitStruct(name, props));
    return name;
  }

  private emitStruct(name: string, props: Prop[]): string {
    const stored = props.filter((p) => p.constValue === undefined);
    const decl = stored
      .map((p) => `    public var ${p.swift}: ${p.type}${p.required && !p.nullable ? "" : "?"}`)
      .join("\n");
    const initParams = stored
      .map((p) => `${p.swift}: ${p.type}${p.required && !p.nullable ? "" : "? = nil"}`)
      .join(", ");
    const initBody = stored.map((p) => `        self.${p.swift} = ${p.swift}`).join("\n");
    const keys = props.map((p) => (p.swift.replace(/`/g, "") === p.json ? `        case ${p.swift}` : `        case ${p.swift} = ${q(p.json)}`)).join("\n");
    const allowed = props.map((p) => q(p.json)).join(", ");
    const dec: string[] = [];
    for (const p of props) {
      if (p.constValue !== undefined) {
        const lit = typeof p.constValue === "string" ? q(p.constValue) : String(p.constValue);
        const ty = typeof p.constValue === "string" ? "String" : "Int";
        dec.push(`        guard try c.decode(${ty}.self, forKey: .${p.swift}) == ${lit} else { throw ContractError("${name}: ${p.json} must be ${p.constValue}") }`);
        continue;
      }
      const sw = `self.${p.swift}`;
      if (p.required && p.nullable) {
        dec.push(`        if try c.decodeNil(forKey: .${p.swift}) { ${sw} = nil } else { ${sw} = try c.decode(${p.type}.self, forKey: .${p.swift}) }`);
      } else if (p.required) {
        dec.push(`        ${sw} = try c.decode(${p.type}.self, forKey: .${p.swift})`);
      } else {
        dec.push(`        ${sw} = try c.decodeIfPresent(${p.type}.self, forKey: .${p.swift})`);
      }
      const chk = this.checks("v", p.schema, p.json);
      if (chk.length > 0) {
        const open = p.required && !p.nullable ? `        do { let v = ${sw}` : `        if let v = ${sw} {`;
        dec.push(open, ...chk.map((l) => `            ${l}`), "        }");
      }
    }
    const enc: string[] = [];
    for (const p of props) {
      if (p.constValue !== undefined) {
        enc.push(`        try c.encode(${typeof p.constValue === "string" ? q(p.constValue) : String(p.constValue)}, forKey: .${p.swift})`);
      } else if (p.required && p.nullable) {
        enc.push(`        if let v = ${p.swift} { try c.encode(v, forKey: .${p.swift}) } else { try c.encodeNil(forKey: .${p.swift}) }`);
      } else if (p.required) {
        enc.push(`        try c.encode(${p.swift}, forKey: .${p.swift})`);
      } else {
        enc.push(`        try c.encodeIfPresent(${p.swift}, forKey: .${p.swift})`);
      }
    }
    return `public struct ${name}: Codable, Equatable, Sendable {
${decl}

    public init(${initParams}) {
${initBody}
    }

    private enum CodingKeys: String, CodingKey {
${keys}
    }

    public init(from decoder: any Decoder) throws {
        try StrictKeys.check(decoder, allowed: [${allowed}], type: ${q(name)})
        let c = try decoder.container(keyedBy: CodingKeys.self)
${dec.join("\n")}
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
${enc.join("\n")}
    }
}
`;
  }

  /** An enum over objects that share a string `const` discriminator. */
  private union(schema: Schema, prefix: string, hint: string, forcedName?: string): string {
    const key = keyOf(schema);
    const known = this.byKey.get(key);
    if (known) return known;
    const variants = schema.oneOf as Schema[];
    const disc = Object.keys(variants[0].properties).find((k) => variants.every((v) => typeof v.properties?.[k]?.const === "string"));
    if (!disc) throw new Error(`${prefix}${hint}: oneOf has no shared const discriminator`);
    const name = forcedName ?? this.unique(`${prefix}${pascal(hint)}`);
    this.byKey.set(key, name);
    const cases: { value: string; swift: string; type: string; props: Prop[] }[] = [];
    for (const v of variants) {
      const value = v.properties[disc].const as string;
      const type = this.struct(v, this.rootName, value);
      cases.push({ value, swift: esc(camel(value)), type, props: this.props(v, this.rootName) });
    }
    // Properties every variant has with the same Swift type become readable on the enum itself.
    const common = cases[0]!.props
      .filter((p) => p.constValue === undefined && p.required && !p.nullable)
      .filter((p) => cases.every((c) => c.props.some((o) => o.json === p.json && o.type === p.type && o.required && o.constValue === undefined)));
    const commonDecls = common
      .map((p) => `    public var ${p.swift}: ${p.type} {\n        switch self {\n${cases.map((c) => `        case .${c.swift}(let v): return v.${p.swift}`).join("\n")}\n        }\n    }`)
      .join("\n\n");
    const caseDecls = cases.map((c) => `    case ${c.swift}(${c.type})`).join("\n");
    const decode = cases.map((c) => `        case ${q(c.value)}: self = .${c.swift}(try ${c.type}(from: decoder))`).join("\n");
    const encode = cases.map((c) => `        case .${c.swift}(let v): try v.encode(to: encoder)`).join("\n");
    const kindSwitch = cases.map((c) => `        case .${c.swift}: return ${q(c.value)}`).join("\n");
    this.chunks.push(`public enum ${name}: Codable, Equatable, Sendable {
${caseDecls}

    /// The value of \`${disc}\`.
    public var ${esc(camel(disc))}: String {
        switch self {
${kindSwitch}
        }
    }
${commonDecls ? `\n${commonDecls}\n` : ""}
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        let tag = try c.decode(String.self, forKey: AnyKey(${q(disc)}))
        switch tag {
${decode}
        default: throw ContractError("${name}: unknown ${disc} \\(tag)")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        switch self {
${encode}
        }
    }
}
`);
    return name;
  }

  root(file: string, schema: Schema): void {
    const name = pascal(file.replace(/\.schema\.json$/, ""));
    this.rootName = name;
    if (schema.oneOf) this.union(schema, "", name, name);
    else this.struct(schema, "", name, name);
  }
}

const SUPPORT = `import Foundation

/// A decoding or validation failure of a generated contract type.
public struct ContractError: Error, Equatable, CustomStringConvertible, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

struct AnyKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil
    init(_ s: String) { stringValue = s }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

/// \`additionalProperties: false\`: a key the schema does not name fails the decode.
enum StrictKeys {
    static func check(_ decoder: any Decoder, allowed: [String], type: String) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        let ok = Set(allowed)
        for key in c.allKeys where !ok.contains(key.stringValue) {
            throw ContractError("\\(type): unknown key \\(key.stringValue)")
        }
    }
}

/// Schema bounds. String lengths count UTF-16 code units: the stricter of the JSON Schema and zod counts (API.md section 3).
enum Check {
    static func length(_ s: String, min: Int?, max: Int?, field: String) throws {
        if let min, s.unicodeScalars.count < min { throw ContractError("\\(field): shorter than \\(min)") }
        if let max, s.utf16.count > max { throw ContractError("\\(field): longer than \\(max)") }
    }

    static func range(_ v: Double, min: Double?, max: Double?, field: String) throws {
        if let min, v < min { throw ContractError("\\(field): below \\(min)") }
        if let max, v > max { throw ContractError("\\(field): above \\(max)") }
    }

    static func count(_ n: Int, min: Int?, max: Int?, field: String) throws {
        if let min, n < min { throw ContractError("\\(field): fewer than \\(min) items") }
        if let max, n > max { throw ContractError("\\(field): more than \\(max) items") }
    }

    static func pattern(_ s: String, _ pattern: String, field: String) throws {
        guard let re = RegexCache.shared.regex(pattern) else { throw ContractError("\\(field): bad pattern") }
        let whole = NSRange(s.startIndex..., in: s)
        guard re.firstMatch(in: s, options: [], range: whole) != nil else { throw ContractError("\\(field): does not match its pattern") }
    }
}

final class RegexCache: @unchecked Sendable {
    static let shared = RegexCache()
    private let lock = NSLock()
    private var cache: [String: NSRegularExpression] = [:]

    func regex(_ pattern: String) -> NSRegularExpression? {
        lock.lock()
        defer { lock.unlock() }
        if let known = cache[pattern] { return known }
        guard let made = try? NSRegularExpression(pattern: pattern) else { return nil }
        cache[pattern] = made
        return made
    }
}
`;

const HEADER = (from: string) => `// Generated by packages/contracts/scripts/gen-swift.ts from ${from}. Do not edit; run the script.\n// swiftlint:disable all\n`;

function generate(): Map<string, string> {
  const files = readdirSync(SCHEMA_DIR).filter((f) => f.endsWith(".schema.json"));
  const rank = (f: string): number => {
    const i = ORDER.indexOf(f.replace(/\.schema\.json$/, ""));
    return i < 0 ? ORDER.length : i;
  };
  files.sort((a, b) => rank(a) - rank(b) || a.localeCompare(b));
  const em = new Emitter();
  const out = new Map<string, string>();
  out.set("ContractSupport.swift", `${HEADER("(no schema: shared helpers)")}${SUPPORT}`);
  for (const f of files) {
    em.chunks = [];
    em.root(f, JSON.parse(readFileSync(join(SCHEMA_DIR, f), "utf8")));
    // The root type reads first; helper types follow in the order they were met.
    const body = em.chunks.reverse().join("\n");
    out.set(`${pascal(f.replace(/\.schema\.json$/, ""))}.swift`, `${HEADER(`packages/contracts/schemas/${f}`)}import Foundation\n\n${body}`);
  }
  const exclusions = readFileSync(EXCLUSIONS, "utf8").replace(/\n$/, "");
  if (exclusions.includes('"""')) throw new Error("exclusions.builtin.json holds a triple quote");
  out.set(
    "BuiltinExclusions.swift",
    `${HEADER("packages/masking/src/exclusions.builtin.json")}import Foundation

/// The built-in "never watch" list, byte for byte the file the server also uses. Parsed by \`ExclusionPolicy.builtin\`.
public enum BuiltinExclusionsJSON {
    public static let text = #"""
${exclusions}
"""#
}
`,
  );
  return out;
}

const outArg = process.argv.indexOf("--out");
const outDir = outArg >= 0 ? resolve(process.argv[outArg + 1] ?? "") : DEFAULT_OUT;
mkdirSync(outDir, { recursive: true });
for (const f of readdirSync(outDir)) if (f.endsWith(".swift")) rmSync(join(outDir, f));
for (const [name, text] of generate()) writeFileSync(join(outDir, name), text);
