// One worker attempt (old s24 runner.ts + s35 options, rewritten on the ports). The attempt's own approval claim comes
// first; then a fresh worker sandbox with the brief (BUILD.md), the frozen check, the harness and the tokenised
// fixtures in its read-only /check; then up to `tries_per_attempt` worker turns, each followed by the tamper hash and
// an advisory run of the frozen check inside the worker sandbox. The advisory result only decides whether to try
// again: the agent shares that sandbox and could print a pass itself, so the verdict comes from fresh verification
// sandboxes (shards.ts, ADR 0029). The same failing artifact twice in a row stops the attempt (stalled). The held-out
// check never enters a worker sandbox. The sandbox is destroyed however the attempt ends.
import type { ApprovalPort } from "./approvals.ts";
import { checkHash, type CheckSet } from "./checks.ts";
import type { BuildConfig } from "./config.ts";
import { artifactSha256 } from "./hash.ts";
import { checkFolder, parseProof } from "./harness.ts";
import { SandboxInfraError, type Sandbox, type SandboxFile, type SandboxProvider } from "./sandbox/provider.ts";
import { HARNESS_ARGV, HARNESS_ENV, newNonce } from "./shards.ts";

/** Appended to every worker's instructions. Paraphrases obra/superpowers (MIT): test-driven-development (red, green,
 * refactor; watch the test fail first) and verification-before-completion (evidence before claiming done). */
export const TDD_INSTRUCTIONS = [
  "Work test-first. For each thing the tool must do, write a failing test first in tests/, run it and watch it fail for the right reason, then write the least code that makes it pass, then tidy up.",
  "Cover the edges the brief implies (empty input, exact limits, repeated items, unusual characters), not only the examples in the check.",
  "Before you say you are done, run the acceptance check and your own tests and read their output. Done means they pass now, not that they should pass.",
].join("\n");

export interface WorkerTurn {
  sandbox: Sandbox;
  provider: SandboxProvider;
  attempt_id: string;
  ordinal: number;
  try_no: number;
  /** The TDD instructions and BUILD.md. */
  prompt: string;
  /** The frozen check's output from the previous try or attempt, and at most "the held-out check also failed". */
  feedback: string | null;
  /** The attempt's cap; the model egress proxy enforces it per call (m2-08). */
  cap_usd4: number;
}

/** The Agent SDK worker inside the sandbox (m2-07). One turn writes into /work through the provider. */
export interface WorkerPort {
  turn(t: WorkerTurn): Promise<{ spent_usd4: number; turns: number }>;
}

export interface AttemptInput {
  tenant_id: string;
  build_id: string;
  attempt_id: string;
  ordinal: number;
  claim: { approval_id: string; token: string; bound: Record<string, string> };
  brief_md: string;
  visible: CheckSet;
  fixtures: SandboxFile[];
  feedback: string | null;
  cap_usd4: number;
  tag: string;
}

export interface AttemptResult {
  outcome: "built" | "fail" | "cap" | "tamper" | "error";
  /** A provider outage: infra_failed, not billed (ADR 0031). */
  infra: boolean;
  tries: number;
  turns: number;
  spent_usd4: number;
  artifact: SandboxFile[];
  note: string;
  advisory_output: string;
  sandbox_id: string | null;
}

export interface AttemptDeps {
  provider: SandboxProvider;
  worker: WorkerPort;
  approvals: ApprovalPort;
  config: BuildConfig;
  now: () => number;
}

const enc = new TextEncoder();
const TAIL = 4000;
/** Feedback never carries a proof line (or its nonce) from one run into the next. */
export const feedbackText = (s: string) =>
  s
    .split("\n")
    .filter((l) => !l.startsWith("OFFLOAD_PROOF"))
    .join("\n")
    .trim()
    .slice(-TAIL);

export async function runAttempt(d: AttemptDeps, i: AttemptInput): Promise<AttemptResult> {
  const r: AttemptResult = { outcome: "error", infra: false, tries: 0, turns: 0, spent_usd4: 0, artifact: [], note: "", advisory_output: "", sandbox_id: null };
  try {
    await d.approvals.claim({ tenant_id: i.tenant_id, approval_id: i.claim.approval_id, token: i.claim.token, bound: i.claim.bound }, d.now());
  } catch {
    r.note = "This worker's approval claim was refused, so it did not start.";
    return r;
  }
  let sb: Sandbox | null = null;
  try {
    sb = await d.provider.create({ image: d.config.image, vcpu: 2, memory_mb: 4096, wall_ms: d.config.worker_wall_ms, network_allowlist: [], env: {}, tag: i.tag, role: "worker" });
    r.sandbox_id = sb.id;
    await d.provider.putFiles(sb, "check", [
      ...checkFolder(i.visible.content).map((f) => ({ path: f.path, bytes: enc.encode(f.text) })),
      { path: "BUILD.md", bytes: enc.encode(i.brief_md) },
      ...i.fixtures.map((f) => ({ path: `fixtures/${f.path}`, bytes: f.bytes })),
    ]);
    const intact = async () => {
      const f = (await d.provider.getFiles(sb!, "check")).find((x) => x.path === "accept.test.ts");
      return f !== undefined && checkHash(new TextDecoder().decode(f.bytes)) === i.visible.hash;
    };
    if (!(await intact())) {
      r.outcome = "tamper";
      r.note = "The frozen check changed inside the worker's sandbox.";
      return r;
    }
    const prompt = `${TDD_INSTRUCTIONS}\n\n${i.brief_md}`;
    let feedback = i.feedback;
    let lastFailed: string | null = null;
    r.outcome = "fail";
    r.note = "The frozen check did not pass.";
    for (let n = 1; n <= d.config.tries_per_attempt; n++) {
      if (r.spent_usd4 >= i.cap_usd4) {
        r.outcome = "cap";
        r.note = "This worker reached its share of the build cap.";
        break;
      }
      const t = await d.worker.turn({ sandbox: sb, provider: d.provider, attempt_id: i.attempt_id, ordinal: i.ordinal, try_no: n, prompt, feedback, cap_usd4: i.cap_usd4 });
      r.tries = n;
      r.turns += Math.max(0, Math.trunc(t.turns));
      // The egress proxy enforces the cap per call (m2-08); the record never goes past this attempt's reservation.
      r.spent_usd4 = Math.min(i.cap_usd4, r.spent_usd4 + Math.max(0, Math.trunc(t.spent_usd4)));
      if (!(await intact())) {
        r.outcome = "tamper";
        r.note = "The frozen check changed during a try.";
        return r;
      }
      r.artifact = await d.provider.getFiles(sb, "work");
      const sha = artifactSha256(r.artifact);
      const nonce = newNonce();
      const adv = await d.provider.exec(sb, { argv: HARNESS_ARGV, cwd: "/check", stdin: `${nonce}\n`, env: { ...HARNESS_ENV }, timeout_ms: d.config.verify_wall_ms });
      r.advisory_output = feedbackText(`${adv.stdout}${adv.stderr}`);
      if (adv.exit === 0 && parseProof(adv.stdout, nonce).ok) {
        r.outcome = "built";
        r.note = "The frozen check passed in the worker's sandbox; fresh sandboxes decide.";
        break;
      }
      if (d.config.stop_on_stall && lastFailed === sha) {
        r.note = `The worker changed nothing in try ${n} (stalled).`;
        break;
      }
      if (r.spent_usd4 >= i.cap_usd4) {
        r.outcome = "cap";
        r.note = "This worker reached its share of the build cap.";
        break;
      }
      lastFailed = sha;
      feedback = r.advisory_output;
      r.note = `The frozen check failed after ${n} ${n === 1 ? "try" : "tries"}.`;
    }
    return r;
  } catch (e) {
    r.outcome = "error";
    r.infra = e instanceof SandboxInfraError;
    r.note = r.infra ? "Offload's side failed: the sandbox provider did not answer." : "This worker stopped with an error.";
    return r;
  } finally {
    if (sb !== null) await d.provider.destroy(sb).catch(() => undefined);
  }
}
