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
import { dirname, isAbsolute, resolve } from "node:path";
// node:fs through require, never an ESM import: an ESM import here would freeze the check's named imports of node:fs
// before the user-split patch below (mkdtemp) could reach them.
const { realpathSync } = require("node:fs");
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
// The user split (OFFLOAD_BROKER set): this check process runs as the user that owns /check; the built tool must run as
// another user that cannot read it. Bun.spawn and Bun.spawnSync go through the root harness's spawn broker (the only
// process APIs a check may use, checks.ts). Temp folders the check makes are shared with the tool through the group.
const BROKER = process.env.OFFLOAD_BROKER;
const CLIENT = process.env.OFFLOAD_SPAWN_CLIENT;
if (BROKER && CLIENT) {
  const fsm = require("node:fs");
  const wide = (d: string) => { try { fsm.chmodSync(d, 0o770); } catch {} return d; };
  const mk = fsm.mkdtempSync;
  fsm.mkdtempSync = (...a: unknown[]) => wide(mk(...a));
  const mkp = fsm.promises.mkdtemp;
  fsm.promises.mkdtemp = async (...a: unknown[]) => wide(await mkp(...a));
  const mkc = fsm.mkdtemp;
  fsm.mkdtemp = (...a: any[]) => { const cb = a.pop(); return mkc(...a, (e: unknown, d: string) => cb(e, e ? d : wide(d))); };
  const realSync = Bun.spawnSync.bind(Bun);
  const realSpawn = Bun.spawn.bind(Bun);
  const request = (a: any, b: any) => {
    const o = Array.isArray(a) ? { ...(b ?? {}), cmd: a } : { ...(a ?? {}) };
    if (!Array.isArray(o.cmd) || o.cmd.length === 0) throw new Error("Bun.spawn needs a command");
    const s = o.stdin;
    let stdin: string | null = null;
    if (typeof s === "string" || s instanceof Uint8Array || s instanceof ArrayBuffer) stdin = Buffer.from(s as any).toString("base64");
    else if (s !== undefined && s !== null && s !== "ignore" && s !== "inherit") throw new Error("the check may give the tool its stdin as a string or bytes only");
    const req = JSON.stringify({ cmd: o.cmd.map(String), cwd: String(o.cwd ?? process.cwd()), stdin }) + "\n";
    // cwd "/": the client never reads the artifact's bunfig.toml, tsconfig.json or .env
    return { cmd: [process.execPath, "--no-env-file", "--no-install", CLIENT], cwd: "/", stdin: Buffer.from(req), stdout: o.stdout ?? "pipe", stderr: o.stderr ?? "pipe", env: { PATH: process.env.PATH ?? "/usr/bin:/bin", OFFLOAD_BROKER: BROKER } };
  };
  (Bun as any).spawnSync = (a: any, b?: any) => realSync(request(a, b));
  (Bun as any).spawn = (a: any, b?: any) => realSpawn(request(a, b));
  // Every other way to start a process would run the tool as this (the check's) user, who can read the check. The
  // linter refuses them (checks.ts); here they throw at run time too (review round 5). Patched through require, before
  // the check loads, so its imports see the patched functions.
  const refuse = (what: string) => () => { throw new Error("the check may start the built tool only with Bun.spawn or Bun.spawnSync, not " + what); };
  const pin = (o: any, k: string, v: unknown) => { try { Object.defineProperty(o, k, { value: v, writable: false, configurable: false }); } catch { try { o[k] = v; } catch {} } };
  pin(Bun, "$", refuse("Bun.$"));
  const cp = require("node:child_process");
  for (const k of ["spawn", "spawnSync", "exec", "execSync", "execFile", "execFileSync", "fork"]) pin(cp, k, refuse("child_process." + k));
  pin(process, "dlopen", refuse("process.dlopen"));
  pin(globalThis, "Worker", refuse("Worker"));
  const gbm = (process as any).getBuiltinModule?.bind(process);
  if (gbm) {
    pin(process, "getBuiltinModule", (id: string) => {
      const name = String(id).replace(/^node:/, "");
      if (name === "worker_threads" || name === "cluster") refuse(name)();
      return gbm(id);
    });
  }
}
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

/** The trusted harness, run as `bun /check/harness.ts` with the nonce on stdin.
 *
 * USER SPLIT (review round 3). Started as root (PID 1, only CHOWN, SETGID and SETUID), it runs `bun test` as the user
 * that owns /check (OFFLOAD_CHECK_UID; the check, guard and bunfig are 0400) and serves a spawn broker on a Unix socket
 * only that user may connect to. Every process the check starts (Bun.spawn / Bun.spawnSync, routed by the guard) runs
 * through the broker as OFFLOAD_TOOL_UID, in /work, with the check's group (to share its temp folders) and a clean
 * environment. That user cannot read /check, the check's /proc entries or this harness, so the built tool can neither
 * read the held-out check nor the nonce. The split is probed, not assumed: the proof says `split: true` only when a
 * process of the tool's user got EACCES opening the check (a mount that ignores file modes would not). Without root (development, emulation) it runs everything as one user and
 * says so in the proof (`split: false`); a provider that isolates the tool then refuses the pass. */
export const HARNESS_TS = String.raw`// Offload trusted check harness. See services/builder/src/harness.ts. Never imports worker code.
import { spawn, spawnSync } from "node:child_process";
import { chmodSync, chownSync, mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { basename, join, resolve } from "node:path";
const nonce = (await Bun.stdin.text()).trim().slice(0, 256);
const CHECK = process.env.OFFLOAD_CHECK_DIR ?? "/check";
const WS = resolve(process.env.OFFLOAD_WS ?? "/work");
const FILE = basename(process.env.OFFLOAD_CHECK_FILE ?? "accept.test.ts");
const MSG = ${JSON.stringify(BUILDER_IMPORT_REFUSED)};
const PATH = process.env.PATH ?? "/usr/local/bin:/usr/bin:/bin";
const id = (k: string, d: number) => { const v = Number(process.env[k]); return Number.isInteger(v) && v >= 0 ? v : d; };
const SPLIT = process.getuid?.() === 0 && process.env.OFFLOAD_CHECK_UID !== undefined;
const CHECK_UID = id("OFFLOAD_CHECK_UID", 0);
const CHECK_GID = id("OFFLOAD_CHECK_GID", 0);
const TOOL_UID = id("OFFLOAD_TOOL_UID", 65534);
const run = mkdtempSync(join(tmpdir(), "offload-run-"));
// chmod while root still owns it: after the chown, chmod would need CAP_FOWNER, which the container does not grant.
if (SPLIT) { chmodSync(run, 0o711); chownSync(run, CHECK_UID, CHECK_GID); }
const report = join(run, "junit.xml");
const tools = new Set<any>();
let broker: any = null;
let brokerDir = "";
let socketPath = "";
if (SPLIT) {
  brokerDir = mkdtempSync(join(tmpdir(), "offload-broker-"));
  chmodSync(brokerDir, 0o711);
  socketPath = join(brokerDir, "s");
  broker = Bun.listen({
    unix: socketPath,
    socket: {
      open(sock: any) { sock.data = { buf: "", started: false, out: "", ended: false }; },
      drain(sock: any) { flush(sock); },
      data(sock: any, chunk: Buffer) {
        const st = sock.data;
        if (st.started) return;
        st.buf += chunk.toString();
        const nl = st.buf.indexOf("\n");
        if (nl < 0) { if (st.buf.length > 4 * 1024 * 1024) finish(sock, 126); return; }
        st.started = true;
        let req: any = null;
        try { req = JSON.parse(st.buf.slice(0, nl)); } catch {}
        const cmd = req?.cmd;
        const cwd = resolve(String(req?.cwd ?? WS));
        if (!Array.isArray(cmd) || cmd.length === 0 || cmd.length > 1024 || !cmd.every((x: unknown) => typeof x === "string") || !(cwd === WS || cwd.startsWith(WS + "/"))) {
          send(sock, "E", Buffer.from("offload: the tool command was refused (it must run in the workspace)\n"));
          return finish(sock, 126);
        }
        let c: any;
        try {
          c = spawn(cmd[0], cmd.slice(1), { cwd, uid: TOOL_UID, gid: CHECK_GID, env: { PATH, HOME: tmpdir(), TMPDIR: tmpdir() }, stdio: ["pipe", "pipe", "pipe"] });
        } catch {
          send(sock, "E", Buffer.from("offload: the tool could not start\n"));
          return finish(sock, 127);
        }
        tools.add(c);
        c.stdout.on("data", (b: Buffer) => send(sock, "O", b));
        c.stderr.on("data", (b: Buffer) => send(sock, "E", b));
        c.on("error", () => { tools.delete(c); finish(sock, 127); });
        c.on("close", (code: number | null) => { tools.delete(c); finish(sock, code ?? 137); });
        if (typeof req.stdin === "string") c.stdin.end(Buffer.from(req.stdin, "base64")); else c.stdin.end();
      },
      close() {},
      error() {},
    },
  });
  chmodSync(socketPath, 0o600);
  chownSync(socketPath, CHECK_UID, CHECK_GID);
}
function send(sock: any, kind: string, b: Buffer) { sock.data.out += kind + b.toString("base64") + "\n"; flush(sock); }
function finish(sock: any, code: number) { if (sock.data.ended) return; sock.data.ended = true; sock.data.out += "X" + code + "\n"; flush(sock); }
function flush(sock: any) {
  const st = sock.data;
  while (st.out.length > 0) { const n = sock.write(st.out); if (n <= 0) return; st.out = st.out.slice(n); }
  if (st.ended) sock.end();
}
// Probe, do not assume: the split counts only if the tool's user really cannot open the check (a mount that ignores
// file modes, or a check written world-readable, would leave it readable). Run before the check, from "/".
let proven = false;
if (SPLIT) {
  const code = "try { const f = require('node:fs'); f.closeSync(f.openSync(" + JSON.stringify(join(CHECK, FILE)) + ", 'r')); process.exit(0); } catch (e) { process.exit(e && e.code === 'EACCES' ? 3 : 4); }";
  const probe = spawnSync(process.execPath, ["--no-env-file", "-e", code], { cwd: "/", uid: TOOL_UID, gid: CHECK_GID, env: { PATH }, stdio: "ignore", timeout: 30000 });
  proven = probe.status === 3;
}
const env: Record<string, string> = { PATH, HOME: run, TMPDIR: tmpdir(), OFFLOAD_WS: WS, OFFLOAD_WS_RAW: WS, OFFLOAD_REFUSED: MSG, BUN_RUNTIME_TRANSPILER_CACHE_PATH: "0" };
if (SPLIT) { env.OFFLOAD_BROKER = socketPath; env.OFFLOAD_SPAWN_CLIENT = join(CHECK, "spawn-client.ts"); }
// cwd: the read-only check folder, never the artifact (bun reads bunfig.toml, tsconfig.json and .env from there).
const child = spawn(
  process.execPath,
  ["test", "--config=" + join(CHECK, "bunfig.toml"), "--no-env-file", "--no-install", "--reporter=junit", "--reporter-outfile=" + report, join(CHECK, FILE)],
  { cwd: CHECK, env, stdio: ["ignore", "inherit", "inherit"], ...(SPLIT ? { uid: CHECK_UID, gid: CHECK_GID } : {}) },
);
const exit: number = await new Promise((done) => { child.on("close", (code: number | null) => done(code ?? 1)); child.on("error", () => done(127)); });
for (const t of tools) { try { t.kill("SIGKILL"); } catch {} }
if (broker !== null) { try { broker.stop(true); } catch {} try { rmSync(brokerDir, { recursive: true, force: true }); } catch {} }
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
if (!SPLIT) { try { rmSync(run, { recursive: true, force: true }); } catch {} }
const status = exit === 0 && completed ? "pass" : "fail";
process.stdout.write("\nOFFLOAD_PROOF " + JSON.stringify({ nonce, status, exit, completed, tests, swept, split: SPLIT && proven, why }) + "\n");
process.exit(status === "pass" ? 0 : 1);
`;

/** The spawn client: run as the check's user by the guard's Bun.spawn / Bun.spawnSync; asks the harness's broker to run
 * one command as the tool's user and relays its output and exit code. */
export const SPAWN_CLIENT_TS = String.raw`// Offload spawn client. See services/builder/src/harness.ts.
const req = await Bun.stdin.text();
const out: Buffer[] = [];
const err: Buffer[] = [];
let code = 1;
let buf = "";
let pending = req;
await new Promise<void>((done) => {
  Bun.connect({
    unix: process.env.OFFLOAD_BROKER ?? "/nonexistent",
    socket: {
      open(s: any) { const n = s.write(pending); pending = pending.slice(Math.max(0, n)); },
      drain(s: any) { if (pending.length > 0) { const n = s.write(pending); pending = pending.slice(Math.max(0, n)); } },
      data(_s: any, chunk: Buffer) {
        buf += chunk.toString();
        let nl = buf.indexOf("\n");
        while (nl >= 0) {
          const line = buf.slice(0, nl);
          buf = buf.slice(nl + 1);
          if (line[0] === "O") out.push(Buffer.from(line.slice(1), "base64"));
          else if (line[0] === "E") err.push(Buffer.from(line.slice(1), "base64"));
          else if (line[0] === "X") { const c = Number.parseInt(line.slice(1), 10); code = Number.isInteger(c) ? c : 1; }
          nl = buf.indexOf("\n");
        }
      },
      close() { done(); },
      error() { done(); },
      connectError() { err.push(Buffer.from("offload: the spawn broker is not reachable\n")); done(); },
    },
  }).catch(() => done());
});
await Bun.write(Bun.stdout, Buffer.concat(out));
await Bun.write(Bun.stderr, Buffer.concat(err));
process.exit(code);
`;

export interface Proof {
  ok: boolean;
  /** The proof line carried this run's nonce: the check really ran (whatever its result). */
  nonce_ok: boolean;
  status: string | null;
  exit: number | null;
  completed: boolean;
  tests: number;
  /** The harness ran as PID 1 and killed every other process before reading the report. */
  swept: boolean;
  /** The check ran as one user and the built tool as another that could not read it. */
  split: boolean;
}

/** Reads the LAST `OFFLOAD_PROOF` line. ok only for this nonce, status pass, exit 0, completed and at least one test. */
export function parseProof(stdout: string, nonce: string): Proof {
  const none: Proof = { ok: false, nonce_ok: false, status: null, exit: null, completed: false, tests: 0, swept: false, split: false };
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
  return { ok, nonce_ok, status, exit, completed, tests, swept: v["swept"] === true, split: v["split"] === true };
}

/** The read-only check folder of a sandbox. In a verification sandbox the check, its guard and bunfig are 0400: only
 * the check's user reads them, never the built tool (the user split). `readable` (worker sandboxes, where the frozen
 * check is visible to the worker) makes them 0444. The harness and spawn client are read by root and the check user. */
export function checkFolder(content: string, o: { readable?: boolean } = {}): Array<{ path: string; text: string; mode: number }> {
  const priv = o.readable === true ? 0o444 : 0o400;
  return [
    { path: "accept.test.ts", text: content, mode: priv },
    { path: "bunfig.toml", text: SHARD_BUNFIG, mode: priv },
    { path: "guard.ts", text: GUARD_TS, mode: priv },
    { path: "harness.ts", text: HARNESS_TS, mode: 0o444 },
    { path: "spawn-client.ts", text: SPAWN_CLIENT_TS, mode: 0o444 },
  ];
}
