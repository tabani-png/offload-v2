// Product copy lint. Tooling, not feature code. Usage: bun scripts/check-copy.ts [root]
// 1. "Dry run" is removed from the product (docs/adr/0016-no-dry-run.md): no product source may contain
//    dry run / dry-run / dry_run / dryRun / dryrun / preview run, in identifiers, strings or comments.
// 2. User-visible strings must not use banned marketing words (docs/PRODUCT.md#copy-rules) or em dashes.
//    Only string literals in app and copy sources, *.strings / *.xcstrings files and the README tagline are copy.
//    Identifiers and comments are not copy, so kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly is fine.
import { existsSync, readFileSync, readdirSync, statSync } from "node:fs";
import { join, relative, resolve } from "node:path";

const root = resolve(process.argv[2] ?? join(import.meta.dir, ".."));
const skipDirs = new Set(["node_modules", ".git", "dist", ".build", ".swiftpm"]);
const DRY = /dry[ _-]?run|preview run/i;
const BANNED = /\b(generous|unlock|seamless|powerful|at scale|robust|everything you need|built for teams that)\b/i;
const EM_DASH = "—";
const CODE = /\.(ts|tsx|js|jsx|mjs|swift)$/;
const STRINGS = /\.(strings|xcstrings|stringsdict)$/;

function walk(dir: string, out: string[] = []): string[] {
  if (!existsSync(dir)) return out;
  for (const name of readdirSync(dir)) {
    if (skipDirs.has(name)) continue;
    const p = join(dir, name);
    if (statSync(p).isDirectory()) walk(p, out);
    else out.push(p);
  }
  return out;
}

function children(dir: string): string[] {
  const d = join(root, dir);
  return existsSync(d) ? readdirSync(d).filter((n) => statSync(join(d, n)).isDirectory()).map((n) => join(d, n)) : [];
}

/** String literal contents with their 1-based line, skipping // and block comments. */
export function literals(src: string): { text: string; line: number }[] {
  const out: { text: string; line: number }[] = [];
  let i = 0;
  let line = 1;
  while (i < src.length) {
    const c = src[i];
    if (c === "\n") { line++; i++; continue; }
    if (c === "/" && src[i + 1] === "/") { while (i < src.length && src[i] !== "\n") i++; continue; }
    if (c === "/" && src[i + 1] === "*") {
      i += 2;
      while (i < src.length && !(src[i] === "*" && src[i + 1] === "/")) { if (src[i] === "\n") line++; i++; }
      i += 2; continue;
    }
    if (c === '"' || c === "'" || c === "`") {
      const triple = c === '"' && src.startsWith('"""', i);
      const close = triple ? '"""' : c;
      const multiline = triple || c === "`";
      const start = line;
      i += close.length;
      let text = "";
      while (i < src.length && !src.startsWith(close, i)) {
        if (src[i] === "\\") { text += src.slice(i, i + 2); i += 2; continue; }
        if (src[i] === "\n") { if (!multiline) break; line++; }
        text += src[i]; i++;
      }
      i += close.length;
      out.push({ text, line: start });
      continue;
    }
    i++;
  }
  return out;
}

const problems: string[] = [];
const rel = (p: string) => relative(root, p);

// 1. Dry-run terms anywhere in product sources.
const productDirs = [
  ...children("apps").map((a) => (a.endsWith("/mac") ? a : join(a, "src"))),
  ...children("packages").map((p) => join(p, "src")),
  ...children("services").map((s) => join(s, "src")),
  ...children("ee/packages").map((p) => join(p, "src")),
];
for (const f of productDirs.flatMap((d) => walk(d))) {
  if (!CODE.test(f) && !STRINGS.test(f) && !f.endsWith(".json")) continue;
  readFileSync(f, "utf8").split("\n").forEach((l, n) => {
    if (DRY.test(l)) problems.push(`${rel(f)}:${n + 1}: dry-run term (ADR 0016): ${l.trim()}`);
  });
}

// 2. User-visible strings.
const copyDirs = [
  ...children("apps").map((a) => (a.endsWith("/mac") ? a : join(a, "src"))),
  join(root, "packages/contracts/src/copy"),
];
for (const f of copyDirs.flatMap((d) => walk(d))) {
  if (/\/Tests\/|\/tests\//.test(rel(f))) continue;
  const src = readFileSync(f, "utf8");
  const items = STRINGS.test(f)
    ? src.split("\n").map((text, n) => ({ text, line: n + 1 }))
    : CODE.test(f) ? literals(src) : [];
  for (const { text, line } of items) {
    const m = text.match(BANNED);
    if (m) problems.push(`${rel(f)}:${line}: banned word "${m[0]}" in product copy: ${text.trim()}`);
    if (text.includes(EM_DASH)) problems.push(`${rel(f)}:${line}: em dash in product copy: ${text.trim()}`);
  }
}

// 3. README tagline (first 5 lines).
const readme = join(root, "README.md");
if (existsSync(readme)) {
  readFileSync(readme, "utf8").split("\n").slice(0, 5).forEach((l, n) => {
    if (BANNED.test(l) || DRY.test(l) || l.includes(EM_DASH)) problems.push(`README.md:${n + 1}: tagline: ${l.trim()}`);
  });
}

if (problems.length) {
  console.error("copy: product copy problems:\n" + problems.join("\n"));
  process.exit(1);
}
console.log("copy: ok");
