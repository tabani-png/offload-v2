// OK, build and the build workflow (old builder/loop.ts, s35, rewritten for v2; ARCHITECTURE section 8).
//
//   okBuild   the user's OK: every hash and the cap must equal what the fix designer froze; a held-out check any
//             earlier build of the brief was bound to is refused (ADR 0029); the insert under the one-live-build-per-brief
//             rule IS the lock (old s35 had an await between its gate and its lock file, so two OKs could both get
//             202); then the exact-hash, single-use, 24 h build approval is minted. The token goes to the workflow in
//             process only.
//   runBuild  claims the approval first (nothing runs without it); re-checks every frozen hash and the check bytes
//             (tampered); allocates the first worker's cap before anything runs (capped, nothing spent); teeth gate:
//             both checks run on an empty workspace in fresh sandboxes and must fail without writing into it; ONE
//             test-first worker (ADR 0012); its artifact goes to fresh verification sandboxes, one per shard (frozen,
//             held-out), any failing shard = FAIL; on FAIL only, `fanout_workers` more workers in parallel, each with
//             its own pre-allocated cap and its own approval claim, fed the frozen check output and only the fact that
//             the held-out check failed; winner: all shards pass, then cost, then smaller artifact (MIGRATION 5.6).
//             An attempt never rejects, and the build waits for every attempt it started before it ends (473cafb).
//
// Notes stored on the build are fixed plain words chosen here: no exception text, paths, tokens or held-out output.
import { ApprovalError } from "./approvals.ts";
import { runAttempt, feedbackText, type AttemptResult, type WorkerPort } from "./attempt.ts";
import { checkHash, renderBuildMd } from "./checks.ts";
import { toUsd4, usd4Text, type BuildConfig } from "./config.ts";
import type { FixStore, FrozenFix } from "./fixes.ts";
import { artifactSha256, canonicalJson, HEX64, sha256Hex } from "./hash.ts";
import type { ApprovalPort } from "./approvals.ts";
import { runShards, type Shard, type ShardResult } from "./shards.ts";
import type { SandboxProvider, SandboxSpec } from "./sandbox/provider.ts";
import { BuildConflict, BuildEnded, HeldOutUsed, type AttemptRow, type BuildRow, type BuildState, type BuildStore, type Stage } from "./store.ts";

export interface BuildDeps {
  store: BuildStore;
  approvals: ApprovalPort;
  fixes: FixStore;
  provider: SandboxProvider;
  worker: WorkerPort;
  config: BuildConfig;
  now: () => number;
  ids: () => string;
}

export type OkBuildCode = "invalid_request" | "not_found" | "hash_mismatch" | "already_running" | "state_conflict";
export class OkBuildError extends Error {
  constructor(readonly code: OkBuildCode, message: string) {
    super(message);
  }
}

export interface OkBuildBody {
  brief_hash: string;
  check_set_hash: string;
  held_out_hash: string;
  fixture_set_hash: string;
  cap_usd: number;
}
const HASH_KEYS = ["brief_hash", "check_set_hash", "held_out_hash", "fixture_set_hash"] as const;

export function parseOkBuildBody(v: unknown): OkBuildBody | null {
  if (typeof v !== "object" || v === null || Array.isArray(v)) return null;
  const o = v as Record<string, unknown>;
  for (const k of HASH_KEYS) if (typeof o[k] !== "string" || !HEX64.test(o[k] as string)) return null;
  if (typeof o["cap_usd"] !== "number" || !Number.isFinite(o["cap_usd"])) return null;
  return { brief_hash: o["brief_hash"] as string, check_set_hash: o["check_set_hash"] as string, held_out_hash: o["held_out_hash"] as string, fixture_set_hash: o["fixture_set_hash"] as string, cap_usd: o["cap_usd"] as number };
}

/** The four frozen hashes and the cap, as bound into the approval. */
export const boundOf = (f: FrozenFix, cap_usd4: number): Record<string, string> => ({
  brief_hash: f.brief_hash,
  check_set_hash: f.check_set.hash,
  held_out_hash: f.held_out.hash,
  fixture_set_hash: f.fixture_set_hash,
  cap_usd: usd4Text(cap_usd4),
});

export async function okBuild(d: BuildDeps, i: { tenant_id: string; member_id: string; fix_id: string; body: unknown }): Promise<{ build_id: string; token: string }> {
  const body = parseOkBuildBody(i.body);
  if (body === null) throw new OkBuildError("invalid_request", "brief_hash, check_set_hash, held_out_hash and fixture_set_hash must be sha256 hex; cap_usd a number");
  const fix = await d.fixes.frozen(i.tenant_id, i.fix_id);
  if (fix === null) throw new OkBuildError("not_found", "no such fix");
  const want = boundOf(fix, d.config.cap_usd4);
  for (const k of HASH_KEYS) if (body[k] !== want[k]) throw new OkBuildError("hash_mismatch", `${k} is not this fix's current value: review it again`);
  if (toUsd4(body.cap_usd) !== d.config.cap_usd4) throw new OkBuildError("hash_mismatch", `cap_usd must be ${usd4Text(d.config.cap_usd4)}`);
  const build_id = d.ids();
  try {
    await d.store.insertQueued({ tenant_id: i.tenant_id, id: build_id, fix_id: fix.fix_id, brief_id: fix.brief_id, cap_usd4: d.config.cap_usd4, fanout_workers: d.config.fanout_workers, bound_hashes: want }, d.now(), d.config.stale_after_ms);
  } catch (e) {
    if (e instanceof BuildConflict) throw new OkBuildError("already_running", "a build of this fix is queued or running");
    if (e instanceof HeldOutUsed) throw new OkBuildError("state_conflict", "this held-out check was already used by a build of this brief; a new one is written before the next build (ADR 0029)");
    throw e;
  }
  try {
    const { approval_id, token } = await d.approvals.mint({ tenant_id: i.tenant_id, kind: "build", subject_id: build_id, bound: want, approver_kind: "person", approver_member_id: i.member_id }, d.now());
    await d.store.update(i.tenant_id, build_id, { approval_id }, d.now());
    return { build_id, token };
  } catch (e) {
    // Never leave a queued build without an approval holding the lock.
    const now = d.now();
    await d.store.update(i.tenant_id, build_id, { state: "failed", ended_at: now, stages: [{ name: "end", state: "failed", started_at: now, ended_at: now, note: "The OK, build approval could not be recorded. Press OK, build again." }] }, now).catch(() => undefined);
    throw e;
  }
}

/** Winner among passing attempts: all shards passed, then lower cost, then smaller artifact, then earlier. */
export function pickWinner(xs: readonly AttemptRow[]): AttemptRow | null {
  const ok = xs.filter((a) => a.outcome === "pass" && a.frozen_pass === true && a.held_out_pass === true);
  ok.sort((a, b) => a.spent_usd4 - b.spent_usd4 || a.artifact_bytes - b.artifact_bytes || a.ordinal - b.ordinal);
  return ok[0] ?? null;
}

const shardWords = (s: string) => (s === "held_out" ? "held-out" : "frozen");

export async function runBuild(d: BuildDeps, i: { tenant_id: string; build_id: string; token: string }): Promise<void> {
  try {
    await runBuildInner(d, i);
  } catch (e) {
    // Ended by someone else (stale recovery): stop, write nothing more. Attempts it started finish on their own and
    // are stopped by their next heartbeat.
    if (e instanceof BuildEnded) return;
    throw e;
  }
}

async function runBuildInner(d: BuildDeps, i: { tenant_id: string; build_id: string; token: string }): Promise<void> {
  const first = await d.store.get(i.tenant_id, i.build_id);
  if (first === null || first.state !== "queued" || first.approval_id === null) return;
  const b: BuildRow = first;
  const stages: Stage[] = [...b.stages];
  const save = (patch: Parameters<BuildStore["update"]>[2]) => d.store.update(i.tenant_id, i.build_id, { stages, ...patch }, d.now());
  const begin = async (name: string, state?: BuildState) => {
    stages.push({ name, state: "running", started_at: d.now(), ended_at: null, note: null });
    await save(state === undefined ? {} : { state });
  };
  const done = (ok = true, note: string | null = null) => {
    const s = stages.at(-1);
    if (s !== undefined && s.ended_at === null) Object.assign(s, { state: ok ? "done" : "failed", ended_at: d.now(), note });
  };
  const end = async (state: BuildState, note: string | null) => {
    const last = stages.at(-1);
    if (last !== undefined && last.ended_at === null) done(state === "ready", note);
    else stages.push({ name: "end", state: state === "ready" ? "done" : "failed", started_at: d.now(), ended_at: d.now(), note });
    await save({ state, ended_at: d.now() });
  };

  // 0. Start once: queued -> building is a compare-and-set. A second start (a re-delivered or re-run workflow) loses
  // here and returns without writing, so it can never claim the approval a second time and fail the live build.
  if (!(await d.store.startBuild(i.tenant_id, i.build_id, d.now()))) return;

  // 1. The approval, claimed once by this workflow. Nothing runs before it.
  try {
    await d.approvals.claim({ tenant_id: i.tenant_id, approval_id: b.approval_id!, token: i.token, bound: b.bound_hashes, kind: "build", subject_id: b.id }, d.now());
  } catch (e) {
    const code = e instanceof ApprovalError ? e.code : null;
    const note = code === "approval_expired" ? "The OK, build approval expired (older than 24 hours). Press OK, build again." : code === "approval_used" ? "The OK, build approval was already used." : "The OK, build approval could not be used.";
    await end("failed", note);
    return;
  }

  // 2. The frozen inputs, re-checked against the approval and their own bytes.
  const fix = await d.fixes.frozen(i.tenant_id, b.fix_id);
  if (fix === null) return void (await end("failed", "The fix is gone."));
  const bound = boundOf(fix, b.cap_usd4);
  const intact = checkHash(fix.check_set.content) === fix.check_set.hash && checkHash(fix.held_out.content) === fix.held_out.hash;
  if (!intact || Object.keys(bound).some((k) => bound[k] !== b.bound_hashes[k])) return void (await end("tampered", "A frozen check or hash changed after OK, build."));

  // 3. The cap first: nothing is paid for when it cannot fund one worker.
  const ceiling = b.cap_usd4 - d.config.checks_reserve_usd4;
  const cap = d.config.attempt_cap_usd4;
  if (cap > ceiling) return void (await end("capped", "The build budget is too small for one worker. Nothing was spent."));

  const tag = `offload-build-${b.id}`;
  const verifySpec: SandboxSpec = { image: d.config.image, vcpu: 1, memory_mb: 2048, wall_ms: d.config.verify_wall_ms, network_allowlist: [], env: {}, tag, role: "verification" };
  const shards: Shard[] = [
    { name: "frozen", check: fix.check_set },
    { name: "held_out", check: fix.held_out },
  ];
  // Model money settled under any scope (build or infra). ADR 0031: the approval is released only with none.
  let spentAny = 0;
  const releaseIfUnspent = async () => {
    if (spentAny === 0) await d.approvals.release({ tenant_id: i.tenant_id, approval_id: b.approval_id! }, d.now()).catch(() => undefined);
  };
  const infraNote = "Offload's side failed: the sandbox provider did not answer. Spend during the outage is not billed to the cap.";

  // 4. Teeth gate: each check must fail on an empty workspace, and leave it unchanged.
  await begin("teeth_gate");
  const teeth = await runShards({ provider: d.provider, spec: verifySpec, artifact: [], shards, timeout_ms: d.config.verify_wall_ms });
  if (teeth.some((t) => t.error === "infra")) {
    await releaseIfUnspent();
    return void (await end("infra_failed", infraNote));
  }
  const toothless = teeth.find((t) => t.passed);
  if (toothless !== undefined) return void (await end("failed", `Needs you: the ${shardWords(toothless.shard)} check passes on an empty workspace (no teeth).`));
  if (teeth.some((t) => t.wrote_workspace)) return void (await end("failed", "Needs you: a check wrote into the workspace."));
  if (teeth.some((t) => !t.ran)) return void (await end("failed", "The teeth gate could not run the checks."));
  done();

  // 5. Workers. Each attempt: its cap reserved, its own claim, a fresh worker sandbox, fresh verification sandboxes.
  const brief_md = renderBuildMd(fix.brief, fix.check_set);
  const definitions = new Map<string, string | null>();
  type Ran = { row: AttemptRow; frozenOutput: string; heldOutFailed: boolean; infra: boolean };
  const attemptOnce = async (ordinal: number, feedback: string | null): Promise<Ran | null> => {
    const id = d.ids();
    if (!(await d.store.reserve({ tenant_id: i.tenant_id, build_id: b.id, attempt_id: id, call_id: `attempt:${id}`, kind: "model", usd4: cap, ceiling_usd4: ceiling }, d.now()))) return null;
    const startedAt = d.now();
    const row: AttemptRow = { tenant_id: i.tenant_id, id, build_id: b.id, ordinal, sandbox_provider: d.provider.name, sandbox_id: null, outcome: "error", spent_usd4: 0, tries: 0, turns: 0, frozen_pass: null, held_out_pass: null, check_groups: [], artifact_sha256: null, artifact_bytes: 0, artifact_files: [], note: "" };
    let res: AttemptResult | null = null;
    let infra = false;
    let frozenOutput = "";
    let heldOutFailed = false;
    try {
      const attemptBound = { ...b.bound_hashes, attempt_ordinal: String(ordinal) };
      let claim: { approval_id: string; token: string };
      try {
        claim = await d.approvals.mint({ tenant_id: i.tenant_id, kind: "build", subject_id: id, bound: attemptBound, approver_kind: "policy", rule_id: "core.build.attempt", parent_approval_id: b.approval_id! }, d.now());
      } catch {
        row.note = "This worker's approval claim could not be made, so it did not start.";
        return { row, frozenOutput, heldOutFailed, infra: false };
      }
      // The row exists (outcome running) before the worker starts, so a crash still leaves a record of the attempt.
      try {
        await d.store.putAttempt({ ...row, outcome: "running", note: "This worker is building." });
      } catch {
        row.note = "This worker could not be recorded, so it did not start.";
        return { row, frozenOutput, heldOutFailed, infra: false };
      }
      const beat = () => d.store.heartbeat(i.tenant_id, b.id, d.now());
      res = await runAttempt({ provider: d.provider, worker: d.worker, approvals: d.approvals, config: d.config, now: d.now, beat }, { tenant_id: i.tenant_id, build_id: b.id, attempt_id: id, ordinal, claim: { ...claim, bound: attemptBound }, brief_md, visible: fix.check_set, fixtures: fix.fixtures, feedback, cap_usd4: cap, tag });
      Object.assign(row, { sandbox_id: res.sandbox_id, tries: res.tries, turns: res.turns, spent_usd4: res.spent_usd4, note: res.note });
      frozenOutput = res.advisory_output;
      if (res.artifact.length > 0) {
        row.artifact_sha256 = artifactSha256(res.artifact);
        row.artifact_bytes = res.artifact.reduce((t, f) => t + f.bytes.length, 0);
        row.artifact_files = res.artifact.map((f) => f.path);
        definitions.set(id, definitionHash(res.artifact));
      }
      if (res.outcome === "tamper") row.outcome = "tamper";
      else if (res.outcome === "error") row.outcome = "error";
      else if (res.tries > 0 && res.artifact.length > 0) {
        // The only pass that counts: fresh verification sandboxes, one per shard, in parallel.
        await beat();
        const v: ShardResult[] = await runShards({ provider: d.provider, spec: verifySpec, artifact: res.artifact, shards, timeout_ms: d.config.verify_wall_ms });
        if (v.some((x) => x.error === "infra")) {
          // A provider outage is not a check result: no verdict, not billed to the cap, no fan-out (ADR 0031).
          infra = true;
          row.outcome = "error";
          row.note = "Offload's side failed while checking this worker; the checks did not run.";
          return { row, frozenOutput, heldOutFailed, infra };
        }
        const f = v.find((x) => x.shard === "frozen")!;
        const h = v.find((x) => x.shard === "held_out")!;
        row.frozen_pass = f.passed;
        row.held_out_pass = h.passed;
        row.check_groups = v.map((x) => ({ name: x.shard, passed: x.passed ? 1 : 0, failed: x.passed ? 0 : 1 }));
        row.proof = Object.fromEntries(v.map((x) => [x.shard, x.proof === null ? null : { status: x.proof.status, exit: x.proof.exit, tests: x.proof.tests, completed: x.proof.completed, swept: x.proof.swept, split: x.proof.split }]));
        frozenOutput = feedbackText(f.output);
        heldOutFailed = !h.passed;
        if (f.passed && h.passed) {
          row.outcome = "pass";
          row.note = "Passed every check in fresh sandboxes.";
        } else {
          row.outcome = res.outcome === "cap" ? "cap" : "fail";
          const failed = v.filter((x) => !x.passed).map((x) => `the ${shardWords(x.shard)} check`);
          row.note = `${res.outcome === "built" ? "" : `${res.note} `}Failed ${failed.join(" and ")} in a fresh sandbox.`.trim();
        }
      } else row.outcome = res.outcome === "cap" ? "cap" : "fail";
      infra = res.infra;
      return { row, frozenOutput, heldOutFailed, infra };
    } catch (e) {
      // The build ended under this worker (stale recovery): its spend is infra, never billed to a cap (ADR 0031).
      if (e instanceof BuildEnded) infra = true;
      row.outcome = "error";
      row.note = "This worker stopped with an error.";
      return { row, frozenOutput, heldOutFailed, infra };
    } finally {
      // Spend during a provider outage is recorded as infra and never billed to the cap (ADR 0031).
      spentAny += row.spent_usd4;
      row.wall_seconds = Math.max(0, Math.round((d.now() - startedAt) / 1000));
      await d.store.settle({ tenant_id: i.tenant_id, build_id: b.id, call_id: `attempt:${id}`, idempotency_key: `attempt:${id}`, scope: infra ? "infra" : "build", usd4: row.spent_usd4 }, d.now()).catch(() => undefined);
      await d.store.putAttempt(row).catch(() => undefined);
    }
  };

  await begin("worker");
  const one = await attemptOnce(1, null);
  if (one === null) return void (await end("capped", "The build budget is too small for one worker."));
  done(true);
  await begin("verification", "verifying");
  const r1 = one.row;
  if (r1.outcome === "tamper") return void (await end("tampered", "The frozen check changed during a try; the build stopped."));
  if (one.infra) {
    await releaseIfUnspent();
    return void (await end("infra_failed", infraNote));
  }
  const ran: Ran[] = [one];
  if (r1.outcome !== "pass") {
    // No fan-out when the first attempt never tried or stopped with an error: fresh workers would stop there too.
    if (r1.outcome === "error" || r1.tries === 0) return void (await end("failed", `The first worker stopped before a check could judge it. ${r1.note}`.trim()));
    done(false, `The first worker did not pass: ${r1.note}`);
    await begin("fan_out", "fanning_out");
    const fb = [one.frozenOutput, one.heldOutFailed ? "The held-out check also failed." : ""].filter((x) => x !== "").join("\n");
    const room = Math.floor(Math.max(0, ceiling - ((await d.store.get(i.tenant_id, i.build_id))?.spent_usd4 ?? 0)) / cap);
    const n = Math.min(b.fanout_workers, room);
    // Every attempt promise resolves (never rejects): the build waits for all of them before it goes on or ends.
    const more = (await Promise.all(Array.from({ length: n }, (_, k) => attemptOnce(2 + k, fb)))).filter((x): x is NonNullable<typeof x> => x !== null);
    ran.push(...more);
    if (more.some((x) => x.row.outcome === "tamper")) return void (await end("tampered", "A frozen check changed during a try; the build stopped."));
    // ADR 0012 step 6: reaching the cap ends the build capped. No fan-out worker fit (no room, or every reservation
    // refused), so the build stopped on money, not on a check verdict of a worker it could pay for.
    if (more.length === 0) return void (await end("capped", `The build cap leaves no room for another worker. Worker 1: ${r1.note}`));
    done(true);
  } else done(true);

  // 6. The winner, the artifact hash, the receipt.
  await begin("winner");
  const win = pickWinner(ran.map((x) => x.row));
  if (win === null) {
    if (ran.some((x) => x.infra)) {
      await releaseIfUnspent();
      return void (await end("infra_failed", infraNote));
    }
    const why = ran.map((x) => `Worker ${x.row.ordinal}: ${x.row.note}`).join(" ");
    return void (await end("failed", `No build passed every check. ${why}`.trim()));
  }
  const attempts = await d.store.attempts(i.tenant_id, i.build_id);
  const definition_hash = definitions.get(win.id) ?? null;
  const after = (await d.store.get(i.tenant_id, i.build_id))!;
  const receipt = {
    build_id: b.id,
    brief_hash: b.bound_hashes["brief_hash"],
    check_set_hash: b.bound_hashes["check_set_hash"],
    held_out_hash: b.bound_hashes["held_out_hash"],
    fixture_set_hash: b.bound_hashes["fixture_set_hash"],
    cap_usd: usd4Text(b.cap_usd4),
    spent_usd: usd4Text(after.spent_usd4),
    artifact_sha256: win.artifact_sha256,
    definition_hash,
    winner_attempt_id: win.id,
    attempts: attempts.map((a) => ({ id: a.id, ordinal: a.ordinal, outcome: a.outcome, spent_usd: usd4Text(a.spent_usd4), frozen_pass: a.frozen_pass, held_out_pass: a.held_out_pass, sandbox_provider: a.sandbox_provider, artifact_sha256: a.artifact_sha256 })),
  };
  done(true, `Ready: worker ${win.ordinal} passed every check. Deploying is its own approval.`);
  await save({ state: "ready", ended_at: d.now(), winner_attempt_id: win.id, artifact_sha256: win.artifact_sha256, definition_hash, receipt, receipt_hash: sha256Hex(canonicalJson(receipt)) });
}

/** The routine definition hash: canonical JSON of routine.json in the artifact (m2-09 adds resolved connections). */
export function definitionHash(files: ReadonlyArray<{ path: string; bytes: Uint8Array }>): string | null {
  const f = files.find((x) => x.path === "routine.json");
  if (f === undefined) return null;
  try {
    return sha256Hex(canonicalJson(JSON.parse(new TextDecoder().decode(f.bytes))));
  } catch {
    return null;
  }
}
