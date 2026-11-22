// Check shards in fresh verification sandboxes (old container.ts appleContainerShards, rewritten on the
// SandboxProvider port). One sandbox per shard, all in parallel, each with its own copy of the artifact in /work and
// only its own check (plus guard and harness) in the read-only /check. Any failing shard is a FAIL; an exec error, a
// timeout, a bad artifact path or a missing proof is a failed shard, never a pass (ADR 0011, ADR 0029). Old shards
// passed on the container's exit code alone; here the harness's nonce proof must match too.
import { randomBytes } from "node:crypto";
import type { CheckSet } from "./checks.ts";
import { checkFolder, parseProof, type Proof } from "./harness.ts";
import { safeRelPath, SandboxInfraError, type SandboxFile, type SandboxProvider, type SandboxSpec } from "./sandbox/provider.ts";

export type ShardName = "frozen" | "held_out";
export interface Shard {
  name: ShardName;
  check: CheckSet;
}
export interface ShardResult {
  shard: ShardName;
  passed: boolean;
  exit: number | null;
  proof: Proof | null;
  /** The tail of the check's output. Held-out output never leaves the builder (fan-out sees only that it failed). */
  output: string;
  /** The harness's proof carried this run's nonce: the check ran (passed or not). */
  ran: boolean;
  /** Why it could not run: a provider outage (infra) or anything else (exec). */
  error: "infra" | "exec" | null;
  /** The check changed /work (refused by the teeth gate). */
  wrote_workspace: boolean;
  sandbox_id: string | null;
  ms: number;
}

const enc = new TextEncoder();
const OUTPUT_TAIL = 4000;
export const newNonce = () => randomBytes(24).toString("base64url");

/** The harness command and environment, the same in every sandbox. */
export const HARNESS_ARGV = ["bun", "/check/harness.ts"];
export const HARNESS_ENV = { OFFLOAD_WS: "/work", OFFLOAD_CHECK_DIR: "/check", OFFLOAD_CHECK_FILE: "accept.test.ts" };

export async function runShards(o: {
  provider: SandboxProvider;
  spec: SandboxSpec;
  artifact: SandboxFile[];
  shards: Shard[];
  timeout_ms: number;
  nonce?: () => string;
}): Promise<ShardResult[]> {
  const nonce = o.nonce ?? newNonce;
  return Promise.all(
    o.shards.map(async (s): Promise<ShardResult> => {
      const t0 = Date.now();
      const fail = (output: string, sandbox_id: string | null, error: "infra" | "exec" = "exec"): ShardResult => ({ shard: s.name, passed: false, ran: false, error, exit: null, proof: null, output, wrote_workspace: false, sandbox_id, ms: Date.now() - t0 });
      try {
        for (const f of o.artifact) safeRelPath(f.path);
      } catch {
        return fail("the artifact has a path outside the workspace", null);
      }
      let sb: Awaited<ReturnType<SandboxProvider["create"]>> | null = null;
      try {
        sb = await o.provider.create(o.spec);
        await o.provider.putFiles(sb, "work", o.artifact);
        await o.provider.putFiles(sb, "check", checkFolder(s.check.content).map((f) => ({ path: f.path, bytes: enc.encode(f.text), mode: f.mode })));
        const before = await o.provider.snapshot(sb, "work");
        const n = nonce();
        const r = await o.provider.exec(sb, { argv: HARNESS_ARGV, cwd: "/check", stdin: `${n}\n`, env: { ...HARNESS_ENV }, timeout_ms: o.timeout_ms, harness: true });
        const after = await o.provider.snapshot(sb, "work");
        const proof = parseProof(r.stdout, n);
        const output = `${r.stdout}${r.stderr}`.slice(-OUTPUT_TAIL);
        if (r.timed_out || r.exit === null) return { ...fail("the check did not finish in time", sb.id), output };
        // With the user split, a pass also needs the harness's word that the tool ran as a user that could not read the check.
        const isolated = o.provider.isolates_tool !== true || proof.split;
        return { shard: s.name, passed: r.exit === 0 && proof.ok && isolated, ran: proof.nonce_ok, error: null, exit: r.exit, proof, output, wrote_workspace: before !== after, sandbox_id: sb.id, ms: Date.now() - t0 };
      } catch (e) {
        return fail("the check could not run", sb?.id ?? null, e instanceof SandboxInfraError ? "infra" : "exec");
      } finally {
        if (sb !== null) await o.provider.destroy(sb).catch(() => undefined);
      }
    }),
  );
}
