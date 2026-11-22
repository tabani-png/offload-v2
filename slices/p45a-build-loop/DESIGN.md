# p45a/p45b design note: porting old PR #45 (s35 "OK, build")

Source: old repo `feat/build-loop` at `473cafb` (`f075da0` implementation + `473cafb` Claude Code hardening). Binding
plan: [MIGRATION 5.6](../../docs/MIGRATION.md#56-pr-45-featbuild-loop-s35-ok-build) and the 2.6 builder rows. Words
follow the [glossary](../../docs/GLOSSARY.md): build, attempt (worker), check set, held-out check, teeth gate, fan-out,
verification sandbox, nonce proof, tamper hash, build cap.

## 1. Old file → v2 file

| Old (`brain/src/…`) | Fate | v2 |
|---|---|---|
| `builder/loop.ts` | port as code (rewrite) | `services/builder/src/loop.ts` (build workflow), `src/budget.ts` |
| `builder/runner.ts` (s24 tries, stall, teeth) | rewrite | `src/attempt.ts` (one attempt: claim, sandbox, tries, stall, tamper hash) |
| `builder/heldout.ts` | rewrite | `src/heldout.ts` |
| `builder/checks.ts` | rewrite (TypeScript checks only, `check_sets.language`) | `src/checks.ts` (reply parsing, import rule, builder-facing BUILD.md) |
| `builder/container.ts` | rewrite | `src/sandbox/docker.ts` (Docker provider), `src/shards.ts` (shards, teeth runs) |
| `builder/harness.ts` | keep protocol | `src/harness.ts`: `GUARD_TS` kept; nonce proof moves from the Python harness to a Bun harness |
| `builder/supervisor.ts`, `sandbox.ts` | drop | `sandbox-exec` profiles and the per-command supervisor; the sweep is `kill(-1)` from PID 1 in the container |
| `builder/approval.ts` | rewrite | `src/approvals.ts`: local `ApprovalPort` + in-memory adapter |
| `builder/record.ts` | rewrite | `src/store.ts` (`BuildStore` port, memory adapter), `src/store-pg.ts` + `sql/0001_builder.sql` |
| `builder/{routes,service}.ts` | rewrite | `src/http.ts`: web-standard `Request → Response` handlers for `/v1/fixes/{id}/build-approvals` and `/v1/builds/*` |
| `builder/cli.ts` | drop | debug CLI; a later `offload` CLI calls the handlers |
| `builder/outcomes.ts` | rewrite | `packages/hours-saved/src/measured/` (slice p45b) |
| `models/local.ts` | handed to m5-03 | not ported here, see section 5 |

## 2. Holes in the old code and how v2 keeps them closed

Fixed by `473cafb` (each keeps a red test in v2):
1. **Fake PASS through planted files.** A bun shard ran with cwd `/work` (the artifact) and no guard, so a planted
   `bunfig.toml` preload, `node_modules` package, tsconfig `paths`, `package.json` `imports` or `.env` was loaded into
   the check. v2: the check folder is a separate read-only mount at `/check` (cwd), bun gets `--config=/check/bunfig.toml
   --no-env-file`, the guard is preloaded and refuses resolving or loading any file under `/work`. Tests plant real files
   and run real bun (`SHARDS:`).
2. **Unrecoverable stale lock.** v2: the lock is a partial unique index (one non-terminal build per brief). A build whose
   `heartbeat_at` is older than `STALE_AFTER_MS` (twice the longest stage) is ended `infra_failed` by the next OK in the
   same transaction (`LOCK:`).
3. **Orphaned builders.** A refused approval during fan-out ended the session while builders ran. v2: an attempt's
   promise never rejects (any error is that attempt's `error` outcome); the build waits for every attempt before it ends.
4. **Fan-out after a gate stopped the first run.** v2: teeth and write gates run before any attempt; an attempt with zero
   tries never fans out.
5. **Held-out check had no teeth run in container mode.** v2: one teeth gate for both checks, always in fresh sandboxes.
6. **Budget checked after spending.** v2: the first attempt's cap is allocated before any sandbox or model call.
7. **Internal paths in stored records.** v2: rows and views carry ids, hashes and fixed plain-word notes only.
8. **Two concurrent OKs both 202** (an await between gate and lock). v2: the insert under the unique index *is* the lock.
9. **Ship twice wiped measured weeks.** v2: `deployed_at` is set once (`UPDATE … WHERE deployed_at IS NULL`); the second
   deploy is 409 `state_conflict`; `recordShip` in p45b never overwrites.
10. **Weeks measured from the wrong days.** p45b measures a week from its own stored days, × 7 / days stored, else null.

Found in this review (not fixed by `473cafb`):
11. **Shard PASS was the container's exit code alone**, against the old repo's own rule. Bun 1.4.4 exits 0 when no test
    ran. v2 shards run the trusted harness: nonce on stdin, `OFFLOAD_PROOF` line, PASS only for exit 0 + matching nonce +
    status `pass` + at least one test in the JUnit report (`PROOF:`).
12. **Containers ran as root** with no `no-new-privileges` or pids limit. v2 adds `--user 65534:65534`,
    `--security-opt no-new-privileges`, `--pids-limit`, `--memory`, `--cpus`, and only allowlisted env names.
13. **The held-out writer saw the whole visible check** (`<visible_check>` in the prompt): copying was easy and ADR 0012
    says it never sees the check set. v2: it sees the brief and the visible check's interface (file, entry points,
    output format), never its body (`HELDOUT:`).
14. **Copy detection was `trim()` equality**: an added comment passed. v2 compares with comments and whitespace removed.
15. **The loop approved itself.** `approveBuild` was called by the loop with the brief hash it already had; the user's
    OK was not an approval record. v2: only the OK handler mints the build approval (four hashes + cap, 24 h TTL); the
    workflow claims it once; each attempt's claim is minted only from that claimed approval (`approver_kind = policy`,
    rule `core.build.attempt`) and claimed once by its attempt (`GATE:`).
16. **No approval TTL; only two hashes bound.** v2: 24 h TTL (`approval_expired`), all four hashes and `cap_usd`.
17. **Exception text stored in records** (`msg(err)` could hold paths or model output). v2 stores fixed notes.
18. **Float thresholds** (`ratio >= 0.8`). p45b compares integer tenths of minutes.
19. **A timed-out shard left its VM running** (the CLI client was killed, not the container). v2 runs `docker rm -f`
    on timeout and on `destroy`.
20. **In-runner held-out mode** (no containers) ran the held-out check in the builder's own same-uid sandbox. Dropped:
    the verdict comes only from fresh verification sandboxes ([ADR 0029](../../docs/adr/0029-build-verdicts.md)).

## 3. Sandboxes: SandboxProvider port (ADR 0011)

`src/sandbox/provider.ts` is the port: `create(spec) → sandbox`, `exec`, `putFiles`, `getFiles`, `snapshot`,
`destroy`, `list(tag)`. Spec: image, vCPU, memory, wall time, `network_allowlist`, env, tag `offload-build-<build_id>`.
- `docker` (self-host, dev): a sandbox is two private host folders (`work`, `check`) plus labels; every `exec` is
  `docker run --rm -i --network none --read-only --cap-drop ALL --security-opt no-new-privileges --pids-limit 256
  --user 65534:65534 --tmpfs /tmp --mount …/work → /work --mount …/check → /check,readonly`. The executor is injected,
  so tests pin the exact argv and the exec-error rule with a fake; a `LIVE:` test runs real Docker and skips without it.
  A non-empty `network_allowlist` is refused until the egress proxy network lands (m2-08).
- `e2b` (Offload Cloud): `src/sandbox/cloud.ts` stub; `create` throws an infra error (m2-08 builds it).
- `apple-container` and `sandbox-exec`: dropped (MIGRATION 5.6).
Shards: one fresh sandbox per check shard (visible, held-out), run in parallel, each with its own copy of the artifact;
any failing shard is FAIL; an exec error, a timeout or a missing proof is a failed shard, never a pass; sandboxes are
destroyed in `finally`.

## 4. Ports and stubs for other streams (local interfaces, adapters land later)

| Port | Owner | Here |
|---|---|---|
| `ApprovalPort` (`mint`, `claim`, `release`) | m2-06, `packages/policy` + `packages/db` `approvals` | exact-hash, single-use, 24 h TTL, `sha256(token)` at rest, constant-time compare; memory adapter |
| `ModelPort` (`complete({ route, system, prompt })`) | W1-F model router (m1-05/m5-03) | route `check_write` for the held-out writer; tests use a fake |
| `DurableRuntime` (`start(name, ids)`) | W1-C (m1-01/m1-03) | inline adapter; inputs are ids only. The approval token is handed over in process and never persisted: how a durable workflow gets the claim after a crash is m2-06's open point. Starting is a compare-and-set (`startBuild`, queued to building); the durable adapter must not re-enter `runBuild` after the claim: a crashed build is recovered as stale (`infra_failed`) |
| `FixStore` (frozen brief, check set, held-out, fixtures by fix id) | m2-05 (brain) | memory adapter in tests |
| `WorkerPort` (`turn` of the Agent SDK worker) | m2-07 | fake in tests; the TDD instructions (superpowers, paraphrased) are passed in |
| `RoutinePort` (`deploy`) | m2-09 (runtime) | returns `{ routine_id, version }`; gets `idempotency_key = deploy:<build_id>`, which m2-09 must honour (a retry after a timeout returns the first version) |
| `BuildStore` | builder; SQL in `services/builder/sql/` | memory + Postgres (`Bun.sql`); `packages/db` adopts the SQL with FKs to `tenants` later. `budget_entries` here is the shared ledger of DATA_MODEL section 8 (scopes `design`, `run`, `brain` too): when `packages/db` lands it, keep ONE definition and drop this one |
Hashes: `artifact_sha256`, `receipt_hash` and `definition_hash` use a local canonical JSON (sorted keys, ES number
form, RFC 8785 for our value types) until `packages/contracts` exports JCS (W1-E). Receipt signing is m2-07.

## 5. Dropped, and why

- apple/container and `sandbox-exec` runners, `RUNTIME: containers are used only on macOS…`: builds run in cloud
  sandboxes or Docker; the dev provider is not ported.
- `OFFLOAD_BUILDER_ENABLED`: the build is gated by the approval and the budget ledger.
- `builder-mac.yml.proposed`: v2 builder tests run on Linux.
- Install plan as a local step: the deploy approval replaces it.
- Python checks and harness: v2 check sets are TypeScript only.
- `NO CONTAINERS:` (held-out inside the builder's sandbox) and `LOCAL:` in the loop (the route table picks models).
- CLI tests (`CLI:`), and `OK: the builder still needs OFFLOAD_BUILDER_ENABLED=1`.
- **`models/local.ts` → m5-03** (router local tier). Carry these as its red tests: `LOCAL: off unless
  OFFLOAD_LOCAL_MODEL_URL is set; exo's default port is documented`; `LOCAL: refuses any host that is not loopback`
  (including `http://localhost.evil.com/v1`); `LOCAL: sends an OpenAI chat request (system + user) to /chat/completions
  and returns the text, no credentials`; `LOCAL: an HTTP error or an empty reply throws a short message`. Add: it must
  not follow redirects (`redirect: "error"`), which the old code did.

## 6. Decisions to flag

- **Winner order.** MIGRATION 5.6 (followed here): all shards pass, then cost, then smaller artifact (bytes).
  ADR 0029 and the M6 `WINNER:` test say smallest diff. Owner to reconcile; the rule is one function (`pickWinner`).
- **Fan-out.** `fanout_workers` from config: default 1 (M2), at most 3 (M6). Old tests that fanned out to 3 set it.
- **Held-out reuse** follows ADR 0029: any build of the brief bound to a held-out hash uses it, even one that never
  ran a worker (stale, failed mint, teeth failure, a pre-turn outage). The cost is one held-out regeneration (design
  spend, about $0.10) after Offload's own failure. If the owner prefers "used once a worker started", that is an
  ADR 0029 amendment first, then one query (`HeldOutUsed` in `insertQueued`).
- **Money** is integer ten-thousandths of a dollar (`numeric(10,4)`): cap 40000, checks reserve 3000, attempt cap 7000.
- Verifier, repair turn, replay fixtures, receipt signing, egress proxy and reaper stay with m2-07/m2-08.

## 7. Review gate and known gaps

An independent Opus security review (2026-11-14) confirmed the guard, proof, path, held-out, claim-order, budget and
RLS rules. It also found stale-recovery and deploy issues, now fixed with tests: heartbeats inside attempts,
`BuildEnded`, the attempt row written first, ending the build on a failed mint, kind- and subject-bound claims, a
deploy that can be retried, and p45b's unrounded threshold and stored raw minutes. Open:
- **User split in verification** (review round 3). The Docker harness starts as root (PID 1, only `CHOWN`, `SETGID`,
  `SETUID`), runs the check as the host user that owns `/check` (check, guard, bunfig `0400`) and every tool the check
  starts, through a root-side spawn broker, as another user with the check's group and a clean environment. The tool
  can read neither the held-out check, nor the check's `/proc` entries, nor the harness's nonce; temp folders the check
  makes are shared through the group. Checks may start processes only with `Bun.spawn`/`Bun.spawnSync`, the two the
  guard routes. A provider that isolates the tool refuses proofs without `split: true`. Tested for real with
  passwordless `sudo` (skipped without it: GitHub's hosted runners have it); `privilege_split: false` is development
  only. Open: the `LIVE:` Docker run (it has the cheat case).
- **Approvals are in memory** (`MemoryApprovals`): a restart loses them. The Postgres adapter is m2-06.
- **Durable handoff of the build token**: the inline runner holds it in process (section 4).
- **`LOCAL:` hand-off to m5-03** (owner action: whoever writes m5-03's SPEC). ROADMAP's m5-03 row does not list the
  four `LOCAL:` tests of section 5 or the `redirect: "error"` rule yet, and ROADMAP is outside this slice's scope.
- **Network and registry isolation are proven only by the `LIVE:` Docker test**, which has not run here; the argv test
  pins `--network none` and `--entrypoint`. Run it once on a Docker host before m2-08 relies on it (it now also tries
  a registry and checks that the harness swept as PID 1). `parseProof` reports `swept` but does not require it yet:
  the emulated container in the guard tests is not PID 1. Require it for verification shards when the LIVE run passes.
- **The guard's two hooks**: `onResolve` refuses a path into `/work` at resolution; `onLoad` stops anything that
  resolved there another way (symlink, alias, absolute path). Each has its own test. Data imports (JSON, text) are
  not refused: data is not code.
- **ADR 0031 retry path** (owner: m2-08): the retry endpoint, automatic retries and `infra_retries` are not built.
  `release()` only marks the approval for that endpoint. Retrying the same build keeps its held-out check; a new
  build after `infra_failed` needs a new one (ADR 0029), even when no worker turn ran.
- **Image pin** (owner: spike S4, then m2-08): `docker run --pull never` stops fetching at check time, but the
  default image is the tag `oven/bun:1.4.4`. Pin it by `@sha256:` digest, then refuse non-digest images in config.
- Not ported here: verifier and repair turn, replay fixtures, receipt signing, egress proxy, reaper, E2B, artifact
  object storage, the artifact capability scan (m2-07, m2-08). The `LIVE:` Docker test has not run on this box.
