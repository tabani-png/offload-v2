// SandboxProvider port (ADR 0011). Replaces old sandbox.ts (sandbox-exec) and container.ts (apple/container): builds run
// in cloud sandboxes (e2b) or Docker (self-host, dev). A sandbox has two folders: /work (read-write, the workspace or
// the artifact copy) and /check (read-only: checks, harness, guard, brief, tokenised fixtures). Hard rules for every
// provider: one sandbox per attempt or shard, no secrets inside, network denied, checks read-only, destroyed after.

export type Mount = "work" | "check";
export const MOUNT_PATH: Record<Mount, string> = { work: "/work", check: "/check" };

export interface SandboxSpec {
  /** Prebuilt image with a pinned dependency set; no registry access inside. */
  image: string;
  vcpu: number;
  memory_mb: number;
  wall_ms: number;
  /** Hosts a sandbox may reach. Only the model egress proxy, ever; empty for verification. */
  network_allowlist: string[];
  /** Extra environment: allowlisted names only, never a credential. */
  env: Record<string, string>;
  /** `offload-build-<build_id>`: the reaper's handle (ADR 0031). */
  tag: string;
  role: "worker" | "verification";
}

export interface Sandbox {
  id: string;
  tag: string;
}

export interface SandboxFile {
  path: string;
  bytes: Uint8Array;
}

export interface ExecResult {
  exit: number | null;
  stdout: string;
  stderr: string;
  timed_out: boolean;
}

export interface ExecOptions {
  argv: string[];
  cwd: "/work" | "/check";
  stdin?: string;
  env?: Record<string, string>;
  timeout_ms: number;
}

export interface SandboxProvider {
  readonly name: "docker" | "e2b";
  create(spec: SandboxSpec): Promise<Sandbox>;
  putFiles(s: Sandbox, mount: Mount, files: SandboxFile[]): Promise<void>;
  /** Regular files only, sorted by path; symlinks are never followed. */
  getFiles(s: Sandbox, mount: Mount): Promise<SandboxFile[]>;
  exec(s: Sandbox, o: ExecOptions): Promise<ExecResult>;
  /** A hash of a folder's paths and contents. */
  snapshot(s: Sandbox, mount: Mount): Promise<string>;
  destroy(s: Sandbox): Promise<void>;
  /** Sandbox ids with this tag, for the reaper. */
  list(tag: string): Promise<string[]>;
}

/** A provider outage or refusal: the build ends infra_failed, not billed to the cap (ADR 0031). */
export class SandboxInfraError extends Error {}
/** A spec the provider refuses (a credential-looking env name, a network allowlist it cannot enforce). */
export class SandboxSpecError extends Error {}

/** Environment names a sandbox may carry. Everything else, credentials above all, is refused. */
export const SANDBOX_ENV_NAMES: ReadonlySet<string> = new Set(["OFFLOAD_WS", "OFFLOAD_WS_RAW", "OFFLOAD_CHECK_DIR", "OFFLOAD_CHECK_FILE", "OFFLOAD_REFUSED", "LANG", "TZ", "NO_COLOR"]);

export function checkEnv(env: Record<string, string> | undefined): void {
  for (const k of Object.keys(env ?? {})) if (!SANDBOX_ENV_NAMES.has(k)) throw new SandboxSpecError(`environment name ${JSON.stringify(k)} is not allowed in a sandbox`);
}

/** A file path inside a sandbox folder: relative, no "..", no empty or "." parts, no NUL, no backslash. */
export function safeRelPath(p: string): string {
  if (typeof p !== "string" || p === "" || p.length > 512 || p.startsWith("/") || p.includes("\u0000") || p.includes("\\")) throw new SandboxSpecError("path escapes the sandbox folder");
  const parts = p.split("/");
  if (parts.some((x) => x === "" || x === "." || x === "..")) throw new SandboxSpecError("path escapes the sandbox folder");
  return p;
}
