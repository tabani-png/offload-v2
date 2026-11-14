// Parses every .github/workflows/*.yml with Bun's YAML parser and checks each has jobs with runs-on and steps.
// Tooling, not feature code. Usage: bun scripts/check-workflows.ts [root]
import { existsSync, readFileSync, readdirSync } from "node:fs";
import { join, resolve } from "node:path";

const root = resolve(process.argv[2] ?? join(import.meta.dir, ".."));
const dir = join(root, ".github/workflows");
const problems: string[] = [];
const files = existsSync(dir) ? readdirSync(dir).filter((f) => /\.ya?ml$/.test(f)) : [];
for (const f of files) {
  let doc: any;
  try {
    doc = Bun.YAML.parse(readFileSync(join(dir, f), "utf8"));
  } catch (e) {
    problems.push(`${f}: YAML parse error: ${(e as Error).message}`);
    continue;
  }
  const jobs = doc?.jobs;
  if (!jobs || typeof jobs !== "object" || !Object.keys(jobs).length) { problems.push(`${f}: no jobs`); continue; }
  for (const [name, job] of Object.entries<any>(jobs)) {
    if (!job?.["runs-on"]) problems.push(`${f}: job ${name} has no runs-on`);
    if (!Array.isArray(job?.steps) || !job.steps.length) problems.push(`${f}: job ${name} has no steps`);
  }
}
if (problems.length) {
  console.error("workflows:\n" + problems.join("\n"));
  process.exit(1);
}
console.log(`workflows: ok (${files.length} files)`);
