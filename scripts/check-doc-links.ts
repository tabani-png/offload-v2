// Checks that every relative Markdown link in the repo resolves to a file (and, for
// #anchors into Markdown files, to a heading). Tooling, not feature code.
// Usage: bun scripts/check-doc-links.ts [root]
import { existsSync, readFileSync, readdirSync, statSync } from "node:fs";
import { dirname, join, relative, resolve } from "node:path";

const root = resolve(process.argv[2] ?? join(import.meta.dir, ".."));
const skipDirs = new Set(["node_modules", ".git", "dist", ".build"]);

function walk(dir: string, out: string[]): string[] {
  for (const name of readdirSync(dir)) {
    if (skipDirs.has(name)) continue;
    const p = join(dir, name);
    if (statSync(p).isDirectory()) walk(p, out);
    else if (p.endsWith(".md")) out.push(p);
  }
  return out;
}

export function slug(heading: string): string {
  return heading
    .trim()
    .toLowerCase()
    .replace(/`/g, "")
    .replace(/[^\p{L}\p{N}\s_-]/gu, "")
    .replace(/\s/g, "-");
}

function anchorsOf(file: string): Set<string> {
  const set = new Set<string>();
  const counts = new Map<string, number>();
  let inFence = false;
  for (const line of readFileSync(file, "utf8").split("\n")) {
    if (line.startsWith("```")) inFence = !inFence;
    if (inFence) continue;
    const m = /^#{1,6}\s+(.*)$/.exec(line);
    if (!m || m[1] === undefined) continue;
    const base = slug(m[1]);
    const n = counts.get(base) ?? 0;
    counts.set(base, n + 1);
    set.add(n === 0 ? base : `${base}-${n}`);
  }
  return set;
}

const problems: string[] = [];
const files = walk(root, []);
const linkRe = /\[[^\]]*\]\(([^)\s]+)(?:\s+"[^"]*")?\)/g;
for (const file of files) {
  let inFence = false;
  const lines = readFileSync(file, "utf8").split("\n");
  lines.forEach((line, i) => {
    if (line.startsWith("```")) inFence = !inFence;
    if (inFence) return;
    for (const m of line.matchAll(linkRe)) {
      const target = m[1];
      if (!target || /^[a-z]+:/i.test(target) || target.startsWith("mailto:")) continue;
      const [pathPart, anchor] = target.split("#") as [string, string | undefined];
      const abs = pathPart === "" ? file : resolve(dirname(file), decodeURIComponent(pathPart));
      const where = `${relative(root, file)}:${i + 1}`;
      if (!existsSync(abs)) {
        problems.push(`${where} -> missing file ${target}`);
        continue;
      }
      if (anchor && abs.endsWith(".md") && !anchorsOf(abs).has(anchor)) {
        problems.push(`${where} -> missing anchor #${anchor} in ${relative(root, abs)}`);
      }
    }
  });
}
if (problems.length > 0) {
  console.error(`doc-links: ${problems.length} broken link(s):\n` + problems.join("\n"));
  process.exit(1);
}
console.log(`doc-links: ok (${files.length} markdown files)`);
