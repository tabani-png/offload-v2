// p45a test fixtures: a fake SandboxProvider (in-memory folders, scripted check verdicts), a scripted worker, a fix
// store with a frozen brief, check set and held-out check, and one call that wires the build. No real model, sandbox or
// network. Real bun and real planted files are used only in guard.test.ts.
import { MemoryApprovals } from "../../src/approvals.ts";
import { checkHash, type Brief, type CheckSet } from "../../src/checks.ts";
import { buildConfig, type BuildConfig } from "../../src/config.ts";
import { sha256Hex } from "../../src/hash.ts";
import { okBuild, runBuild, type BuildDeps } from "../../src/loop.ts";
import type { FixStore, FrozenFix } from "../../src/fixes.ts";
import type { ExecResult, Mount, Sandbox, SandboxFile, SandboxProvider, SandboxSpec } from "../../src/sandbox/provider.ts";
import { MemoryBuildStore } from "../../src/store.ts";
import type { WorkerPort, WorkerTurn } from "../../src/attempt.ts";

export const T0 = Date.UTC(2026, 10, 14, 12, 0, 0);
export const TENANT = "0193a6f2-0000-7000-8000-000000000001";
export const OTHER_TENANT = "0193a6f2-0000-7000-8000-000000000002";
export const MEMBER = "0193a6f2-0000-7000-8000-0000000000aa";
export const FIX = "fix_slugify";

const enc = new TextEncoder();
const dec = new TextDecoder();
export const file = (path: string, text: string): SandboxFile => ({ path, bytes: enc.encode(text) });
export const text = (f: SandboxFile | undefined) => (f === undefined ? "" : dec.decode(f.bytes));

export const BRIEF: Brief = {
  id: "brief_slugify",
  title: "Turn a title into a URL slug",
  inputs: ["a title (text)"],
  outputs: ["the slug (text)"],
  acceptance: ["lowercase", "spaces become single dashes", "an empty title gives an empty slug"],
  capabilities: [],
};

/** Checks are opaque text to the fake harness: FROZEN / HELDOUT markers decide which shard is which. */
export const FROZEN_CONTENT = 'import { expect, test } from "bun:test";\n// FROZEN slug check\ntest("slug", () => { expect(1).toBe(1); });\n';
export const HELDOUT_CONTENT = 'import { expect, test } from "bun:test";\n// HELDOUT boundary check SECRET-HELDOUT-MARKER\ntest("edges", () => { expect(2).toBe(2); });\n';

export const checkSet = (kind: "frozen" | "held_out", content: string): CheckSet => ({
  kind,
  file: "accept.test.ts",
  content,
  hash: checkHash(content),
  interface: { file: "accept.test.ts", entry: ["bun run slug.ts <title>"], output: "the slug on one line" },
  writer_model: "claude-opus-5-5",
});

export function frozenFix(over: Partial<FrozenFix> = {}): FrozenFix {
  const check_set = checkSet("frozen", FROZEN_CONTENT);
  const held_out = checkSet("held_out", HELDOUT_CONTENT);
  const fixtures = [file("instances/1.json", '{"title":"tok_0123456789ab"}\n')];
  return {
    fix_id: FIX,
    brief_id: BRIEF.id,
    brief: BRIEF,
    brief_hash: sha256Hex(JSON.stringify(BRIEF)),
    check_set,
    held_out,
    fixture_set_hash: sha256Hex(text(fixtures[0])),
    fixtures,
    ...over,
  };
}

export class MemoryFixStore implements FixStore {
  readonly fixes = new Map<string, FrozenFix>();
  constructor(f: FrozenFix = frozenFix()) {
    this.fixes.set(`${TENANT}/${f.fix_id}`, f);
  }
  async frozen(tenant_id: string, fix_id: string): Promise<FrozenFix | null> {
    return this.fixes.get(`${tenant_id}/${fix_id}`) ?? null;
  }
}

export const hashesOf = (f: FrozenFix) => ({
  brief_hash: f.brief_hash,
  check_set_hash: f.check_set.hash,
  held_out_hash: f.held_out.hash,
  fixture_set_hash: f.fixture_set_hash,
  cap_usd: 4,
});

// ---- fake sandbox provider -------------------------------------------------------------------------------------

export interface FakeSandbox {
  id: string;
  spec: SandboxSpec;
  work: Map<string, Uint8Array>;
  check: Map<string, Uint8Array>;
  /** File modes asked for in the read-only check folder. */
  modes: Map<string, number>;
  destroyed: boolean;
  execs: Array<{ argv: string[]; stdin: string | undefined; env: Record<string, string>; harness: boolean }>;
}

/** Decides one harness run. `work` is the sandbox's /work, `shard` which check ran, `role` worker or verification. */
export type Verdict = (a: { work: Map<string, Uint8Array>; shard: "frozen" | "held_out"; role: SandboxSpec["role"]; sandbox: FakeSandbox }) =>
  | { pass: boolean; tests?: number; write?: boolean; output?: string; exit?: number; noProof?: boolean; wrongNonce?: boolean; split?: boolean }
  | "throw";

/** Default verdict: an empty workspace fails; otherwise slug.ts containing "good" passes both checks. */
export const goodSlug: Verdict = ({ work }) => ({ pass: text(fileOf(work, "slug.ts")).includes("good") });
const fileOf = (m: Map<string, Uint8Array>, p: string): SandboxFile | undefined => {
  const b = m.get(p);
  return b === undefined ? undefined : { path: p, bytes: b };
};

export class FakeProvider implements SandboxProvider {
  readonly name = "docker" as const;
  readonly sandboxes: FakeSandbox[] = [];
  live = 0;
  maxLiveVerification = 0;
  createError: Error | null = null;
  /** Like the Docker provider with the user split: verification passes need the harness's split proof. */
  isolates_tool = false;
  constructor(public verdict: Verdict = goodSlug) {}

  private sb(s: Sandbox): FakeSandbox {
    const f = this.sandboxes.find((x) => x.id === s.id);
    if (f === undefined || f.destroyed) throw new Error("no such sandbox");
    return f;
  }
  async create(spec: SandboxSpec): Promise<Sandbox> {
    if (this.createError) throw this.createError;
    const f: FakeSandbox = { id: `sbx_${this.sandboxes.length + 1}`, spec, work: new Map(), check: new Map(), modes: new Map(), destroyed: false, execs: [] };
    this.sandboxes.push(f);
    if (spec.role === "verification") {
      this.live++;
      this.maxLiveVerification = Math.max(this.maxLiveVerification, this.live);
    }
    return { id: f.id, tag: spec.tag };
  }
  async putFiles(s: Sandbox, mount: Mount, files: SandboxFile[]): Promise<void> {
    const f = this.sb(s);
    for (const x of files) {
      if (x.path.startsWith("/") || x.path.split("/").includes("..")) throw new Error("path escapes the sandbox folder");
      (mount === "work" ? f.work : f.check).set(x.path, x.bytes);
      if (mount === "check") f.modes.set(x.path, x.mode ?? 0o444);
    }
  }
  async getFiles(s: Sandbox, mount: Mount): Promise<SandboxFile[]> {
    const f = this.sb(s);
    return [...(mount === "work" ? f.work : f.check)].map(([path, bytes]) => ({ path, bytes })).sort((a, b) => (a.path < b.path ? -1 : 1));
  }
  async snapshot(s: Sandbox, mount: Mount): Promise<string> {
    const files = await this.getFiles(s, mount);
    return sha256Hex(files.map((x) => `${x.path}\0${sha256Hex(x.bytes)}`).join("\n"));
  }
  async exec(s: Sandbox, o: { argv: string[]; cwd: string; stdin?: string; env?: Record<string, string>; timeout_ms: number; harness?: boolean }): Promise<ExecResult> {
    const f = this.sb(s);
    f.execs.push({ argv: o.argv, stdin: o.stdin, env: o.env ?? {}, harness: o.harness === true });
    await new Promise((r) => setTimeout(r, 3));
    const check = text(fileOf(f.check, "accept.test.ts"));
    const shard = check.includes("HELDOUT") ? "held_out" : "frozen";
    const v = this.verdict({ work: f.work, shard, role: f.spec.role, sandbox: f });
    if (v === "throw") throw new Error("docker: image not found");
    if (v.write) f.work.set("written-by-check.txt", enc.encode("x"));
    const nonce = v.wrongNonce ? "not-the-nonce" : (o.stdin ?? "").trim();
    const tests = v.tests ?? 1;
    const status = v.pass ? "pass" : "fail";
    const proof = v.noProof ? "" : `\nOFFLOAD_PROOF ${JSON.stringify({ nonce, status, exit: v.pass ? 0 : 1, completed: v.pass && tests > 0, tests, split: v.split ?? false })}\n`;
    return { exit: v.exit ?? (v.pass ? 0 : 1), stdout: `${v.output ?? (v.pass ? "1 pass" : "1 fail")}${proof}`, stderr: "", timed_out: false };
  }
  async destroy(s: Sandbox): Promise<void> {
    const f = this.sandboxes.find((x) => x.id === s.id);
    if (f && !f.destroyed) {
      f.destroyed = true;
      if (f.spec.role === "verification") this.live--;
    }
  }
  async list(tag: string): Promise<string[]> {
    return this.sandboxes.filter((x) => !x.destroyed && x.spec.tag === tag).map((x) => x.id);
  }
  /** Test backdoor: change a file in a sandbox's read-only check folder (a provider that failed to mount it read-only). */
  tamper(id: string, path: string, content: string) {
    this.sandboxes.find((x) => x.id === id)!.check.set(path, enc.encode(content));
  }
  verification() {
    return this.sandboxes.filter((x) => x.spec.role === "verification");
  }
  workers() {
    return this.sandboxes.filter((x) => x.spec.role === "worker");
  }
}

// ---- scripted worker -------------------------------------------------------------------------------------------

export interface WorkerScript {
  /** Files written into /work on every try (default slug.ts "good"). */
  files?: Record<string, string>;
  /** Files per try (overrides `files`). */
  perTry?: Array<Record<string, string>>;
  spent_usd?: number;
  throws?: string;
  delayMs?: number;
  /** Change the check file in the sandbox during the try. */
  tamper?: boolean;
  /** Print a forged proof line from inside the worker sandbox. */
  forgeProof?: boolean;
}

export class ScriptedWorker implements WorkerPort {
  readonly turns: WorkerTurn[] = [];
  live = 0;
  maxLive = 0;
  constructor(public scripts: WorkerScript[], private provider: FakeProvider) {}
  scriptFor(ordinal: number) {
    return this.scripts[Math.min(ordinal - 1, this.scripts.length - 1)]!;
  }
  async turn(t: WorkerTurn): Promise<{ spent_usd4: number; turns: number }> {
    this.turns.push(t);
    const s = this.scriptFor(t.ordinal);
    this.live++;
    this.maxLive = Math.max(this.maxLive, this.live);
    try {
      if (s.delayMs) await new Promise((r) => setTimeout(r, s.delayMs));
      if (s.throws !== undefined) throw new Error(s.throws);
      const files = s.perTry?.[Math.min(t.try_no - 1, s.perTry.length - 1)] ?? s.files ?? { "slug.ts": "// good slug\n", "routine.json": '{"name":"slugify","steps":[]}\n' };
      await t.provider.putFiles(t.sandbox, "work", Object.entries(files).map(([p, c]) => file(p, c)));
      if (s.tamper) this.provider.tamper(t.sandbox.id, "accept.test.ts", "// tampered\n");
      return { spent_usd4: Math.round((s.spent_usd ?? 0.1) * 10_000), turns: 3 };
    } finally {
      this.live--;
    }
  }
}

// ---- wiring ------------------------------------------------------------------------------------------------------

export interface Harness {
  deps: BuildDeps;
  store: MemoryBuildStore;
  approvals: MemoryApprovals;
  fixes: MemoryFixStore;
  provider: FakeProvider;
  worker: ScriptedWorker;
  fix: FrozenFix;
  clock: { now: number };
  /** OK, build with the exact hashes, then run the build to its end. */
  okAndRun: (over?: Partial<ReturnType<typeof hashesOf>>) => Promise<{ build_id: string }>;
}

export function harness(scripts: WorkerScript[] = [{}], o: { verdict?: Verdict; config?: Partial<BuildConfig>; fix?: FrozenFix } = {}): Harness {
  const fix = o.fix ?? frozenFix();
  const provider = new FakeProvider(o.verdict ?? goodSlug);
  const worker = new ScriptedWorker(scripts, provider);
  const store = new MemoryBuildStore();
  const approvals = new MemoryApprovals();
  const fixes = new MemoryFixStore(fix);
  const clock = { now: T0 };
  let n = 0;
  const deps: BuildDeps = {
    store,
    approvals,
    fixes,
    provider,
    worker,
    config: buildConfig(o.config ?? {}),
    now: () => clock.now,
    ids: () => `0193a6f2-${(++n).toString(16).padStart(4, "0")}-7000-8000-${"0".repeat(12)}`,
  };
  const okAndRun = async (over: Partial<ReturnType<typeof hashesOf>> = {}) => {
    const r = await okBuild(deps, { tenant_id: TENANT, member_id: MEMBER, fix_id: FIX, body: { ...hashesOf(fix), ...over } });
    await runBuild(deps, { tenant_id: TENANT, build_id: r.build_id, token: r.token });
    return { build_id: r.build_id };
  };
  return { deps, store, approvals, fixes, provider, worker, fix, clock, okAndRun };
}
