// Parses every .github/workflows/*.yml with Bun's YAML parser and checks each has jobs with runs-on and steps.
// Jobs that run slice checks (check-slices.sh, verify-all.sh, slices/*/verify.sh) must check out full history
// and set env SLICE_UPSTREAM (see scripts/lib/slice-changes.sh).
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
    if (!Array.isArray(job?.steps) || !job.steps.length) { problems.push(`${f}: job ${name} has no steps`); continue; }
    // Slice verify.sh diffs BASE..HEAD; a shallow checkout lacks BASE ("BASE <sha> not found").
    const sliceSteps = job.steps.filter((s: any) =>
      /check-slices\.sh|verify-all\.sh|slices\/[^\s]+\/verify\.sh/.test(String(s?.run ?? "")));
    const runsSlices = sliceSteps.length > 0;
    // Without SLICE_UPSTREAM the scope check blames changes that reached main after BASE on the slice.
    if (sliceSteps.some((s: any) => !s?.env?.SLICE_UPSTREAM && !job?.env?.SLICE_UPSTREAM)) {
      problems.push(`${f}: job ${name} runs slice checks without env SLICE_UPSTREAM`);
    }
    const fullHistory = job.steps.some((s: any) =>
      String(s?.uses ?? "").startsWith("actions/checkout@") && String(s?.with?.["fetch-depth"]) === "0");
    if (runsSlices && !fullHistory) {
      problems.push(`${f}: job ${name} runs slice checks but its actions/checkout lacks fetch-depth: 0`);
    }
  }
}
if (problems.length) {
  console.error("workflows:\n" + problems.join("\n"));
  process.exit(1);
}
console.log(`workflows: ok (${files.length} files)`);
