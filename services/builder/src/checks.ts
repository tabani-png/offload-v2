// Check sets (old builder/checks.ts, rewritten). v2 checks are TypeScript only (`check_sets.language`), one file,
// accept.test.ts, run with bun test. A check may import only bun:/node: builtins or relative files: a bare specifier
// could resolve to a module the worker planted (node_modules, tsconfig paths, package.json imports). The check runs
// the built tool as a subprocess; it never imports worker code (the guard in harness.ts enforces that at run time).
import { builtinModules } from "node:module";
import { sha256Hex } from "./hash.ts";

export const CHECK_FILE = "accept.test.ts";
export const MAX_CHECK_BYTES = 32 * 1024;

/** What a check calls and expects, without its body. The held-out writer sees only this. */
export interface CheckInterface {
  file: typeof CHECK_FILE;
  /** The commands or entry points the check runs, e.g. "bun run slug.ts <title>". */
  entry: string[];
  /** The output the check reads, in words. */
  output: string;
}

export interface CheckSet {
  kind: "frozen" | "held_out";
  file: typeof CHECK_FILE;
  content: string;
  /** sha256 of the exact UTF-8 bytes: check_set_hash or held_out_hash. */
  hash: string;
  interface: CheckInterface;
  writer_model: string;
}

/** The fix brief as the builder reads it (the brain's fix designer writes it, m2-05). */
export interface Brief {
  id: string;
  title: string;
  inputs: string[];
  outputs: string[];
  acceptance: string[];
  capabilities: string[];
}

export const checkHash = (content: string) => sha256Hex(content);

/** {file, content} from a check writer's reply, or why it is refused. A fenced ```json block is accepted. */
export function parseCheckReply(reply: string): { file: typeof CHECK_FILE; content: string } | { reason: string } {
  const fenced = /```(?:json)?\s*\n([\s\S]*?)\n```/.exec(reply);
  let v: unknown;
  try {
    v = JSON.parse((fenced?.[1] ?? reply).trim());
  } catch {
    return { reason: "the check writer did not reply with JSON" };
  }
  if (typeof v !== "object" || v === null || Array.isArray(v)) return { reason: "the reply is not an object" };
  const { file, content } = v as Record<string, unknown>;
  if (file !== CHECK_FILE) return { reason: `file must be ${CHECK_FILE}` };
  if (typeof content !== "string" || content.trim() === "") return { reason: "the check is empty" };
  if (Buffer.byteLength(content, "utf8") > MAX_CHECK_BYTES) return { reason: `the check is over ${MAX_CHECK_BYTES} bytes` };
  if (content.includes("\u0000")) return { reason: "the check has a NUL byte" };
  const bad = disallowedTsImport(content);
  if (bad !== null) return { reason: `the check may only import bun:/node: builtins or relative files; it imports ${bad}` };
  const proc = disallowedProcessApi(content);
  if (proc !== null) return { reason: `the check may start the built tool only with Bun.spawn or Bun.spawnSync; it uses ${proc}` };
  return { file: CHECK_FILE, content };
}

const NODE_BUILTINS = new Set(builtinModules);
const SPECIFIERS = [/\bfrom\s*["']([^"']+)["']/g, /\bimport\s*["']([^"']+)["']/g, /\bimport\s*\(\s*["']([^"']+)["']\s*\)/g, /\brequire\s*\(\s*["']([^"']+)["']\s*\)/g];

/** The first import a check may not have (a bare non-builtin specifier, or a computed import/require), or null. */
export function disallowedTsImport(content: string): string | null {
  if (/\b(?:import|require)\s*\(\s*[^"'\s)]/.test(content)) return "a computed import()/require()";
  for (const re of SPECIFIERS) {
    for (const m of content.matchAll(re)) {
      const spec = m[1]!;
      if (spec.startsWith("./") || spec.startsWith("../") || spec === "bun" || spec.startsWith("bun:") || spec.startsWith("node:") || NODE_BUILTINS.has(spec)) continue;
      return JSON.stringify(spec);
    }
  }
  return null;
}

/** Process APIs a check may not use. With the user split (harness.ts) the guard routes Bun.spawn and Bun.spawnSync to
 * the built tool's own user; any other way to start a process would run the tool as the check's user, which can read the
 * check (and the held-out answers). */
const PROCESS_SPECIFIERS = new Set(["child_process", "node:child_process", "bun:ffi", "worker_threads", "node:worker_threads", "cluster", "node:cluster"]);
const PROCESS_PATTERNS: Array<[RegExp, string]> = [
  [/\bBun\s*\.\s*\$/, "Bun.$"],
  [/\bimport\s*\{[^}]*\$[^}]*\}\s*from\s*["']bun["']/, "$ from bun"],
  [/\bnew\s+Worker\s*\(/, "new Worker()"],
  [/\bprocess\s*\.\s*(?:dlopen|binding|_linkedBinding)\b/, "process.dlopen/binding"],
];

export function disallowedProcessApi(content: string): string | null {
  for (const re of SPECIFIERS) {
    for (const m of content.matchAll(re)) if (PROCESS_SPECIFIERS.has(m[1]!)) return JSON.stringify(m[1]!);
  }
  for (const [re, name] of PROCESS_PATTERNS) if (re.test(content)) return name;
  return null;
}

/** The builder-facing text (BUILD.md in the worker's read-only folder): the brief and the frozen check. It never
 * names, hashes or quotes the held-out check. */
export function renderBuildMd(b: Brief, visible: CheckSet): string {
  const list = (xs: string[]) => (xs.length === 0 ? ["- none"] : xs.map((x) => `- ${x}`));
  return [
    `# ${b.title}`,
    "",
    "## Inputs",
    ...list(b.inputs),
    "",
    "## Outputs",
    ...list(b.outputs),
    "",
    "## It must",
    ...list(b.acceptance),
    "",
    "## Capabilities it may use",
    ...list(b.capabilities),
    "",
    "## Acceptance check (frozen before the build)",
    `File: ${visible.file} (read-only) · sha256: ${visible.hash}`,
    "You cannot change this file; a change ends the build. Other checks you do not see also decide the result.",
    "",
  ].join("\n");
}
