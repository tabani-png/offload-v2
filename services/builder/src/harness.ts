// The trusted check harness and the container guard (old builder/harness.ts protocol, kept; Python dropped: v2 check
// sets are TypeScript only). Both are written into a sandbox's read-only /check folder next to the check.
//
// NONCE PROOF. Exit code 0 alone is never a pass (ADR 0011). The harness reads a nonce on stdin (never argv or env),
// runs `bun test` on the check in a child process, reads bun's JUnit report and prints a final
// `OFFLOAD_PROOF {nonce, status, exit, completed, tests}` line. The builder passes a shard only for exit 0 + its own
// nonce + status pass + at least one test (bun exits 0 when no test ran). In the container the harness is PID 1: after
// the check it SIGKILLs every other process (kill -1) before it reads the report, so no worker process outlives it.
//
// GUARD (the 473cafb fix). The check runs with cwd = /check, a read-only mount OUTSIDE the artifact, with
// `--config=/check/bunfig.toml --no-env-file --no-install`, so bun's resolution root (bunfig.toml, tsconfig.json,
// package.json, node_modules, .env) is the trusted folder, never the worker's. The guard is preloaded from there: it
// chdirs into /work for the check's subprocess and file work, and refuses resolving or loading any file inside /work,
// however it was reached (relative path, bare specifier, node_modules, tsconfig paths, package imports, symlink).

export const BUILDER_IMPORT_REFUSED =
  "the check may not load builder code into its own process (it could fake the result): run the built tool as a subprocess, e.g. Bun.spawnSync([process.execPath, 'run', 'tool.ts', ...])";

/** The bunfig.toml in /check: only the guard preload. */
export const SHARD_BUNFIG = 'preload = ["./guard.ts"]\n\n[test]\npreload = ["./guard.ts"]\n';

/** Bun preload: refuses resolving or loading any workspace file (worker code stays out of the check process). */
export const GUARD_TS = String.raw`// Offload check guard (preloaded from the read-only check folder). See services/builder/src/harness.ts.
import { plugin } from "bun";
import { realpathSync } from "node:fs";
import { dirname, isAbsolute, resolve } from "node:path";
const WS = process.env.OFFLOAD_WS ?? "/nonexistent-offload-ws";
const WS_RAW = process.env.OFFLOAD_WS_RAW ?? WS;
const MSG = process.env.OFFLOAD_REFUSED ?? "builder code may not be imported by the check";
const real = (p: string) => { try { return realpathSync(p); } catch { return p; } };
const inside = (p: string, root: string) => p === root || p.startsWith(root + "/");
const WS_REAL = real(WS);
const builder = (p: string) => inside(p, WS) || inside(p, WS_RAW) || inside(p, WS_REAL) || inside(real(p), WS_REAL);
const esc = (s: string) => s.replace(/[.*+?^\${}()|[\]\\]/g, "\\$&");
// The check's own working directory is the workspace (its subprocess and file work); module resolution started from
// the check folder before this preload ran.
if (process.env.OFFLOAD_WS_RAW) process.chdir(process.env.OFFLOAD_WS_RAW);
plugin({
  name: "offload-check-guard",
  setup(b) {
    b.onResolve({ filter: /.*/ }, (a) => {
      const raw = isAbsolute(a.path) ? a.path : (a.path.startsWith(".") && a.importer) ? resolve(dirname(a.importer), a.path) : null;
      if (raw === null) return undefined;
      for (const p of [raw, raw + ".ts", raw + ".tsx", raw + ".js", raw + ".mjs", raw + ".cjs", raw + ".json", raw + "/index.ts", raw + "/index.js"].map(real)) {
        if (builder(p)) throw new Error(MSG + " (" + p + ")");
      }
      return undefined;
    });
    // The RESOLVED path decides, however it was reached (bare specifier, node_modules, tsconfig paths, symlink):
    // nothing inside the workspace is ever loaded into the check.
    for (const root of new Set([WS, WS_RAW, WS_REAL])) {
      b.onLoad({ filter: new RegExp("^" + esc(root) + "(/|$)") }, (a) => {
        throw new Error(MSG + " (" + a.path + ")");
      });
    }
  },
});
`;

/** The trusted harness, run as `bun /check/harness.ts` with the nonce on stdin. */
export const HARNESS_TS = String.raw`// Offload trusted check harness. See services/builder/src/harness.ts. Never imports worker code.
import { mkdtempSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { basename, join } from "node:path";
const nonce = (await Bun.stdin.text()).trim().slice(0, 256);
const CHECK = process.env.OFFLOAD_CHECK_DIR ?? "/check";
const WS = process.env.OFFLOAD_WS ?? "/work";
const FILE = basename(process.env.OFFLOAD_CHECK_FILE ?? "accept.test.ts");
const MSG = ${JSON.stringify(BUILDER_IMPORT_REFUSED)};
const report = join(mkdtempSync(join(tmpdir(), "offload-report-")), "junit.xml");
const child = Bun.spawn(
  [process.execPath, "test", "--config=" + CHECK + "/bunfig.toml", "--no-env-file", "--no-install", "--reporter=junit", "--reporter-outfile=" + report, CHECK + "/" + FILE],
  {
    cwd: CHECK,
    stdin: "ignore",
    stdout: "inherit",
    stderr: "inherit",
    env: { PATH: process.env.PATH ?? "/usr/local/bin:/usr/bin:/bin", HOME: tmpdir(), TMPDIR: tmpdir(), OFFLOAD_WS: WS, OFFLOAD_WS_RAW: WS, OFFLOAD_REFUSED: MSG },
  },
);
const exit = await child.exited;
// No survivors: as PID 1 of the sandbox, stop every other process before reading the report.
let swept = false;
if (process.pid === 1) {
  try { process.kill(-1, "SIGKILL"); } catch {}
  swept = true;
}
let tests = 0;
let completed = false;
let why = "no complete JUnit report";
try {
  const xml = readFileSync(report, "utf8");
  const root = /<testsuites\b([^>]*)>/.exec(xml);
  if (root !== null && xml.trimEnd().endsWith("</testsuites>")) {
    const n = (k: string) => { const m = new RegExp("\\b" + k + "=\"(\\d+)\"").exec(root[1]!); return m === null ? 0 : Number(m[1]); };
    tests = n("tests") - n("skipped");
    const failing = n("failures") + n("errors");
    completed = failing === 0 && tests >= 1;
    why = failing > 0 ? failing + " failing test(s)" : tests < 1 ? "no test ran" : tests + " test(s) passed";
  }
} catch {}
const status = exit === 0 && completed ? "pass" : "fail";
process.stdout.write("\nOFFLOAD_PROOF " + JSON.stringify({ nonce, status, exit, completed, tests, swept, why }) + "\n");
process.exit(status === "pass" ? 0 : 1);
`;

export interface Proof {
  ok: boolean;
  /** The proof line carried this run's nonce: the check really ran (whatever its result). */
  nonce_ok: boolean;
  status: string | null;
  exit: number | null;
  completed: boolean;
  tests: number;
}

/** Reads the LAST `OFFLOAD_PROOF` line. ok only for this nonce, status pass, exit 0, completed and at least one test. */
export function parseProof(stdout: string, nonce: string): Proof {
  const none: Proof = { ok: false, nonce_ok: false, status: null, exit: null, completed: false, tests: 0 };
  const line = stdout
    .split("\n")
    .filter((l) => l.startsWith("OFFLOAD_PROOF "))
    .at(-1);
  if (line === undefined || nonce === "") return none;
  let v: Record<string, unknown>;
  try {
    v = JSON.parse(line.slice("OFFLOAD_PROOF ".length)) as Record<string, unknown>;
  } catch {
    return none;
  }
  if (typeof v !== "object" || v === null) return none;
  const status = typeof v["status"] === "string" ? (v["status"] as string) : null;
  const exit = typeof v["exit"] === "number" ? (v["exit"] as number) : null;
  const completed = v["completed"] === true;
  const tests = typeof v["tests"] === "number" && Number.isInteger(v["tests"]) ? (v["tests"] as number) : 0;
  const nonce_ok = v["nonce"] === nonce;
  const ok = nonce_ok && status === "pass" && exit === 0 && completed && tests >= 1;
  return { ok, nonce_ok, status, exit, completed, tests };
}

/** The read-only check folder of a sandbox: the check, the guard, its bunfig and the harness. */
export function checkFolder(content: string): Array<{ path: string; text: string }> {
  return [
    { path: "accept.test.ts", text: content },
    { path: "bunfig.toml", text: SHARD_BUNFIG },
    { path: "guard.ts", text: GUARD_TS },
    { path: "harness.ts", text: HARNESS_TS },
  ];
}
