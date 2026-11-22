// Docker SandboxProvider (self-host and dev, ADR 0011). From old container.ts's flags (apple/container's `run`, no code
// copied): no network, read-only root, every capability dropped, the check folder mounted read-only, one sandbox per
// shard, temps removed. Hardened beyond it: no-new-privileges, a pids limit, an env allowlist, a timed-out container
// is removed (the old runner killed the CLI client and left the VM running), and who runs as whom:
//   - every exec runs as 65534:65534 with no added capability (a worker's commands above all);
//   - the ONE exception is the trusted check harness (`exec({ harness: true })`, set only by shards.ts and the advisory
//     run in attempt.ts) on a provider with the user split: it starts as root (PID 1) with only CHOWN, SETGID and
//     SETUID, to run the check and the built tool as two other users (harness.ts).
// A sandbox is two private host folders plus labels and a sandbox.json record; every exec is a fresh `docker run --rm`
// over them. destroy() empties /work from a cleanup container as each owner of files there (no network, no capability,
// only /work mounted), then removes the folders; what it cannot remove stays recorded on disk and in list(tag).
import { chmodSync, lstatSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, readlinkSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { sha256Hex } from "../hash.ts";
import { checkEnv, HARNESS_ARGV, MOUNT_PATH, safeRelPath, SandboxInfraError, SandboxSpecError, type ExecOptions, type ExecResult, type Mount, type Sandbox, type SandboxFile, type SandboxProvider, type SandboxSpec } from "./provider.ts";

/** Runs one host command. Injected so tests pin the argv; spawnExecutor is the real one. */
export type Executor = (argv: string[], o: { stdin?: string; timeout_ms: number }) => Promise<ExecResult>;

const MAX_OUTPUT = 256 * 1024;
/** The record in each sandbox's host folder (id, tag, image), removed last by destroy. */
const RECORD = "sandbox.json";
/** The check runs as the host user that wrote /check (its files are 0400); the tool as another one. */
function splitEnv(): string[] {
  const uid = process.getuid?.() ?? 0;
  const gid = process.getgid?.() ?? 0;
  const tool = uid === 65534 ? 65533 : 65534;
  return ["--env", `OFFLOAD_CHECK_UID=${uid}`, "--env", `OFFLOAD_CHECK_GID=${gid}`, "--env", `OFFLOAD_TOOL_UID=${tool}`];
}
/** The exec is exactly the trusted harness: the only one `harness: true` may start as root (review round 5). */
const isHarnessExec = (o: ExecOptions) => o.cwd === "/check" && o.argv.length === HARNESS_ARGV.length && o.argv.every((a, i) => a === HARNESS_ARGV[i]);
const DOCKER_ERROR_EXITS: ReadonlySet<number> = new Set([125, 126, 127]);
const MAX_FILE = 4 * 1024 * 1024;
const MAX_FILES = 2_000;

export const spawnExecutor: Executor = async (argv, o) => {
  // The docker CLI gets PATH and HOME only: no host environment reaches it, so none can be forwarded by mistake.
  const p = Bun.spawn(argv, { stdin: o.stdin === undefined ? "ignore" : new TextEncoder().encode(o.stdin), stdout: "pipe", stderr: "pipe", env: { PATH: process.env["PATH"] ?? "/usr/local/bin:/usr/bin:/bin", HOME: process.env["HOME"] ?? "/" } });
  let timed_out = false;
  const t = setTimeout(() => {
    timed_out = true;
    p.kill("SIGKILL");
  }, o.timeout_ms);
  const [stdout, stderr, code] = await Promise.all([new Response(p.stdout).text(), new Response(p.stderr).text(), p.exited]);
  clearTimeout(t);
  return { exit: timed_out ? null : code, stdout: stdout.slice(-MAX_OUTPUT), stderr: stderr.slice(-MAX_OUTPUT), timed_out };
};

interface Box {
  sandbox: Sandbox;
  spec: SandboxSpec;
  root: string;
  work: string;
  check: string;
  runs: number;
}

export class DockerProvider implements SandboxProvider {
  readonly name = "docker" as const;
  private readonly executor: Executor;
  private readonly docker: string;
  private readonly root: string;
  private readonly boxes = new Map<string, Box>();

  private readonly split: boolean;

  /** `privilege_split` (default true): the harness starts as root with only CHOWN, SETGID and SETUID, runs the check
   * as the host user that owns /check and the built tool as another user that cannot read it. False is for
   * development only (no root): verdicts then do not prove the held-out check stayed hidden. */
  constructor(o: { executor?: Executor; docker?: string; root?: string; privilege_split?: boolean } = {}) {
    this.split = o.privilege_split ?? true;
    this.executor = o.executor ?? spawnExecutor;
    this.docker = o.docker ?? "docker";
    this.root = o.root ?? tmpdir();
  }

  get isolates_tool(): boolean {
    return this.split;
  }

  async create(spec: SandboxSpec): Promise<Sandbox> {
    checkEnv(spec.env);
    if (spec.network_allowlist.length > 0) throw new SandboxSpecError("the docker provider runs with no network; the egress proxy network is not built yet (m2-08)");
    let root: string;
    try {
      root = mkdtempSync(join(this.root, "offload-sbx-"));
    } catch {
      throw new SandboxInfraError("could not create the sandbox folders");
    }
    const work = join(root, "work");
    const check = join(root, "check");
    mkdirSync(work, { mode: 0o777 });
    mkdirSync(check, { mode: 0o755 });
    // The container user (65534) writes in /work; the host parent stays private (0700), so no other host user can.
    chmodSync(work, 0o777);
    const sandbox: Sandbox = { id: `sbx_${sha256Hex(root).slice(0, 16)}`, tag: spec.tag };
    // The on-disk record: list(tag) and destroy() find the sandbox from it after a restart, or after a removal that
    // failed, so a host folder is never forgotten (review round 5).
    writeFileSync(join(root, RECORD), JSON.stringify({ id: sandbox.id, tag: spec.tag, image: spec.image }), { mode: 0o600 });
    this.boxes.set(sandbox.id, { sandbox, spec, root, work, check, runs: 0 });
    return sandbox;
  }

  /** Sandboxes recorded on disk under this provider's root (also those another process created). */
  private onDisk(): Array<{ id: string; tag: string; image: string; root: string }> {
    const out: Array<{ id: string; tag: string; image: string; root: string }> = [];
    let names: string[] = [];
    try {
      names = readdirSync(this.root).filter((n) => n.startsWith("offload-sbx-"));
    } catch {
      return out;
    }
    for (const n of names) {
      try {
        const r = JSON.parse(readFileSync(join(this.root, n, RECORD), "utf8")) as { id?: unknown; tag?: unknown; image?: unknown };
        if (typeof r.id === "string" && /^sbx_[0-9a-f]{16}$/.test(r.id) && typeof r.tag === "string" && typeof r.image === "string") out.push({ id: r.id, tag: r.tag, image: r.image, root: join(this.root, n) });
      } catch {
        // not a sandbox folder of this provider
      }
    }
    return out;
  }

  /** The uids, other than the builder's, that own anything in a folder (a worker's or a tool's files). */
  private foreignOwners(dir: string): Set<number> {
    const me = process.getuid?.() ?? -1;
    const found = new Set<number>();
    const walk = (d: string) => {
      let names: string[] = [];
      try {
        names = readdirSync(d);
      } catch {
        return;
      }
      for (const n of names) {
        try {
          const st = lstatSync(join(d, n));
          if (st.uid !== me) found.add(st.uid);
          if (st.isDirectory()) walk(join(d, n));
        } catch {
          // gone, or unreadable: its owner was recorded from its parent's listing
        }
      }
    };
    walk(dir);
    return found;
  }

  private box(s: Sandbox): Box {
    const b = this.boxes.get(s.id);
    if (b === undefined) throw new SandboxInfraError("no such sandbox");
    return b;
  }

  /** Host folders of a sandbox (tests and the emulated executor). */
  paths(s: Sandbox): { root: string; work: string; check: string } {
    const b = this.box(s);
    return { root: b.root, work: b.work, check: b.check };
  }

  /** Sandboxes this process created and has not destroyed. */
  known(): Sandbox[] {
    return [...this.boxes.values()].map((b) => b.sandbox);
  }

  async putFiles(s: Sandbox, mount: Mount, files: SandboxFile[]): Promise<void> {
    const b = this.box(s);
    const base = mount === "work" ? b.work : b.check;
    for (const f of files) safeRelPath(f.path);
    for (const f of files) {
      const p = join(base, f.path);
      mkdirSync(dirname(p), { recursive: true, mode: mount === "work" ? 0o777 : 0o755 });
      const mode = f.mode ?? (mount === "work" ? 0o666 : 0o444);
      writeFileSync(p, f.bytes, { mode });
      chmodSync(p, mode);
    }
  }

  async getFiles(s: Sandbox, mount: Mount): Promise<SandboxFile[]> {
    const b = this.box(s);
    const base = mount === "work" ? b.work : b.check;
    const out: SandboxFile[] = [];
    const walk = (dir: string, rel: string) => {
      for (const name of readdirSync(dir).sort()) {
        const r = rel === "" ? name : `${rel}/${name}`;
        const st = lstatSync(join(dir, name));
        if (st.isSymbolicLink()) continue;
        if (st.isDirectory()) walk(join(dir, name), r);
        else if (st.isFile()) {
          if (st.size > MAX_FILE || out.length >= MAX_FILES) throw new SandboxSpecError("the artifact is too large");
          out.push({ path: r, bytes: new Uint8Array(readFileSync(join(dir, name))) });
        }
      }
    };
    walk(base, "");
    return out.sort((x, y) => (x.path < y.path ? -1 : x.path > y.path ? 1 : 0));
  }

  /** Every entry of the folder: files with their content hash, folders (empty ones too), symlinks with their target,
   * anything else by its kind. The teeth gate compares two snapshots: any change means a check wrote. */
  async snapshot(s: Sandbox, mount: Mount): Promise<string> {
    const b = this.box(s);
    const base = mount === "work" ? b.work : b.check;
    const lines: string[] = [];
    const walk = (dir: string, rel: string) => {
      for (const name of readdirSync(dir).sort()) {
        const r = rel === "" ? name : `${rel}/${name}`;
        const p = join(dir, name);
        const st = lstatSync(p);
        if (st.isSymbolicLink()) lines.push(`l ${r}\u0000${readlinkSync(p)}`);
        else if (st.isDirectory()) {
          lines.push(`d ${r}`);
          walk(p, r);
        } else if (st.isFile()) lines.push(`f ${r}\u0000${sha256Hex(readFileSync(p))}`);
        else lines.push(`o ${r}`);
      }
    };
    walk(base, "");
    return sha256Hex(lines.join("\n"));
  }

  /** The exact `docker run` argv for one exec. */
  runArgv(s: Sandbox, name: string, o: ExecOptions): string[] {
    const b = this.box(s);
    // Root (with three capabilities) only for the trusted harness on a split provider; never for anything else.
    const root = this.split && o.harness === true && isHarnessExec(o);
    const env = { ...b.spec.env, ...(o.env ?? {}) };
    const envArgs = Object.keys(env)
      .sort()
      .flatMap((k) => ["--env", `${k}=${env[k]}`]);
    return [
      this.docker, "run", "--rm", "-i",
      "--name", name,
      "--label", `offload.sandbox=${s.id}`,
      "--label", `offload.tag=${b.spec.tag}`,
      "--network", "none",
      // Never fetch an image at check time: the image is prebuilt and on the host (ADR 0011); whoever controls a
      // registry tag would otherwise control the harness that gives the verdict.
      "--pull", "never",
      "--read-only",
      "--cap-drop", "ALL",
      "--security-opt", "no-new-privileges",
      "--pids-limit", "256",
      "--memory", `${b.spec.memory_mb}m`,
      "--cpus", String(b.spec.vcpu),
      ...(root ? ["--user", "0:0", "--cap-add", "CHOWN", "--cap-add", "SETGID", "--cap-add", "SETUID"] : ["--user", "65534:65534"]),
      "--tmpfs", "/tmp:rw,nosuid,nodev,size=64m",
      "--env", "HOME=/tmp",
      "--env", "TMPDIR=/tmp",
      ...(root ? splitEnv() : []),
      ...envArgs,
      "--mount", `type=bind,source=${b.work},target=${MOUNT_PATH.work}`,
      "--mount", `type=bind,source=${b.check},target=${MOUNT_PATH.check},readonly`,
      "--workdir", o.cwd,
      // The image's own entrypoint is never used: argv[0] runs as PID 1 (the harness's kill(-1) sweep needs that).
      "--entrypoint", o.argv[0]!,
      b.spec.image,
      ...o.argv.slice(1),
    ];
  }

  async exec(s: Sandbox, o: ExecOptions): Promise<ExecResult> {
    checkEnv(o.env);
    if (o.argv.length === 0 || o.argv[0] === "") throw new SandboxSpecError("exec needs a command");
    if (o.harness === true && !isHarnessExec(o)) throw new SandboxSpecError("harness: true runs only the trusted harness (bun /check/harness.ts in /check)");
    const b = this.box(s);
    const name = `offload-${s.id}-${++b.runs}`;
    const timeout = Math.min(o.timeout_ms, b.spec.wall_ms);
    let r: ExecResult;
    try {
      r = await this.executor(this.runArgv(s, name, o), { ...(o.stdin === undefined ? {} : { stdin: o.stdin }), timeout_ms: timeout });
    } catch {
      throw new SandboxInfraError("the docker CLI could not run");
    }
    // 125: docker itself failed (daemon, image, flags); 126/127: the command could not be invoked. None is a check
    // result: they are Offload's side failing (ADR 0031), never a check failure billed to the cap.
    if (!r.timed_out && r.exit !== null && DOCKER_ERROR_EXITS.has(r.exit)) throw new SandboxInfraError(`docker run failed (exit ${r.exit})`);
    if (r.timed_out) {
      // Killing the client does not stop the container: remove it.
      await this.executor([this.docker, "rm", "-f", name], { timeout_ms: 30_000 }).catch(() => undefined);
      return { ...r, exit: null };
    }
    return r;
  }

  async destroy(s: Sandbox): Promise<void> {
    try {
      const ps = await this.executor([this.docker, "ps", "-aq", "--filter", `label=offload.sandbox=${s.id}`], { timeout_ms: 30_000 });
      const ids = ps.stdout.split("\n").map((x) => x.trim()).filter((x) => /^[0-9a-f]{6,64}$/.test(x));
      if (ids.length > 0) await this.executor([this.docker, "rm", "-f", ...ids], { timeout_ms: 30_000 });
    } catch {
      // the reaper finds it by its label later (ADR 0031)
    }
    const b = this.boxes.get(s.id);
    const rec = b !== undefined ? { root: b.root, image: b.spec.image } : this.onDisk().find((x) => x.id === s.id);
    if (rec === undefined) return;
    const work = join(rec.root, "work");
    // Files a sandbox user made (a worker's tests/, a tool's output) belong to that uid on the host bind mount, and the
    // builder cannot unlink them. Empty /work from inside a container as each such owner first: no network, no
    // capability, read-only root, only /work mounted.
    for (const uid of this.foreignOwners(work)) {
      try {
        await this.executor(this.cleanupArgv(s.id, work, rec.image, uid), { timeout_ms: 60_000 });
      } catch {
        // removal below fails and the record stays for the next destroy or the reaper
      }
    }
    try {
      rmSync(work, { recursive: true, force: true });
      rmSync(join(rec.root, "check"), { recursive: true, force: true });
      rmSync(rec.root, { recursive: true, force: true });
      this.boxes.delete(s.id);
    } catch {
      // Never thrown at the ending build. sandbox.json is removed last, so the folder stays in list(tag) (from disk)
      // for the next destroy or the reaper (ADR 0031, m2-08).
    }
  }

  /** The cleanup container's argv: `find /work -mindepth 1 -delete` as one owner of files in /work. */
  cleanupArgv(id: string, work: string, image: string, uid: number): string[] {
    return [
      this.docker, "run", "--rm",
      "--name", `offload-${id}-clean-${uid}`,
      "--label", `offload.sandbox=${id}`,
      "--network", "none",
      "--pull", "never",
      "--read-only",
      "--cap-drop", "ALL",
      "--security-opt", "no-new-privileges",
      "--pids-limit", "256",
      "--user", `${uid}:${uid}`,
      "--mount", `type=bind,source=${work},target=${MOUNT_PATH.work}`,
      "--entrypoint", "find",
      image,
      MOUNT_PATH.work, "-mindepth", "1", "-delete",
    ];
  }


  async list(tag: string): Promise<string[]> {
    const ids = new Set([...this.boxes.values()].filter((b) => b.spec.tag === tag).map((b) => b.sandbox.id));
    for (const r of this.onDisk()) if (r.tag === tag) ids.add(r.id);
    try {
      const r = await this.executor([this.docker, "ps", "-a", "--filter", `label=offload.tag=${tag}`, "--format", '{{.Label "offload.sandbox"}}'], { timeout_ms: 30_000 });
      for (const x of r.stdout.split("\n").map((l) => l.trim())) if (/^sbx_[0-9a-f]{16}$/.test(x)) ids.add(x);
    } catch {
      // local view only
    }
    return [...ids].sort();
  }
}
