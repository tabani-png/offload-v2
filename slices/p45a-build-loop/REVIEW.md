# Review: p45a-build-loop and p45b-measured-saving (PR #45 port)

## Round 1

Independent review (Opus 5.5, did not write this code), 2026-11-14, branch `port/build-loop` at `b570ea6`, diff
`8f6ff2d..b570ea6`. Read: AGENTS.md, CLAUDE.md, both SPECs, DESIGN.md, ADR 0003/0004/0011/0012/0029/0030/0031,
DATA_MODEL section 1 and section 6, API.md builds rows, SECURITY_PRIVACY section 13, MIGRATION section 5.6, every
source and test file in the diff, `git log -p` on the tests, and the old code at `/workspace/offload-wsC` (`473cafb`).

### Runs (this reviewer, DATABASE_URL set)

| Command | Result |
|---|---|
| `bash scripts/verify-all.sh` | `verify-all: green`. Full suite **165 tests across 34 files: 164 pass, 1 skip (`LIVE:` Docker), 0 fail**; both done slices PASS; slices, doc links, copy, secrets, workflows ok |
| `bash slices/p45a-build-loop/verify.sh` | `p45a-build-loop: PASS`. Slice suite **98 tests across 10 files: 97 pass, 1 skip, 0 fail** (min 75); all 24 tags present and passing |
| `bash slices/p45b-measured-saving/verify.sh` | `p45b-measured-saving: PASS`. Slice suite **17 tests across 1 file: 17 pass** (min 12); all 6 tags passing |
| Scope | 46 changed files, all inside `paths_in_scope`; nothing in another stream's area; `bun.lock` and `package.json` unchanged; `verify.sh` differs from the template only in the four allowed variables |

### Mutation checks (tests really fail without the code)

Each mutation was applied with `perl -pi`, the two slice suites run, and the file restored with `git checkout --`.
The tree was clean afterwards.

| Mutation | Failing tests |
|---|---|
| `parseProof` ignores the nonce (`harness.ts`) | 1 (`PROOF: exit code 0 without a matching nonce…`) |
| shard pass = exit 0 only (`shards.ts`) | 2 (`PROOF:`) |
| exec error counted as a pass (`shards.ts`) | 3 (`SHARDS:`/`SANDBOX: an exec error…`, `INFRA:`) |
| approvals: single use / TTL / bound-hash check removed (`approvals.ts`) | 3 / 2 / 2 (`GATE:`) |
| OK, build: hash compare off; `brief_hash` alone not compared; cap compare off (`loop.ts`) | 1 each (`GATE: … nothing is stored, minted or started`) |
| build workflow does not claim its approval (`loop.ts`) | 38 |
| attempt does not claim its own approval (`attempt.ts`) | 2 |
| teeth gate: toothless check / writing check not stopped | 2 / 1 (`TEETH:`) |
| held-out hash appended to BUILD.md; held-out output in fan-out feedback | 1 / 1 (`CHECKS:`, `FANOUT:`) |
| tamper re-check off (loop) / in-attempt tamper off | 1 / 1 |
| stale recovery off (memory / Postgres); `BuildEnded` not raised | 2 / 1 / 1 (`LOCK:`) |
| build-lock unique index made non-unique (SQL) | 2 (`LOCK: (Postgres)`) |
| reservation ceiling off (memory / Postgres); `FOR UPDATE` dropped (3 runs) | 1 / 1 / 1,1,1 (`CAP:`) |
| `budget_entries` append-only trigger dropped | 1 (`BUDGET: (Postgres)`) |
| `--network none` dropped; `/check` mounted read-write; no `docker rm -f` on timeout; env allowlist off; `..` paths allowed | 1 / 2 / 1 / 1 / 1 (`SANDBOX:`) |
| deploy: `markDeployed` skipped; hash compare off; no unmark on failure | 2 / 1 / 1 (`SHIP:`, `DEPLOY:`) |
| token in the 202 body; `approval_id` in the Build view | 1 / 1 (`API:`) |
| stall stop off; first-attempt error fans out; release on infra off | 1 / 1 / 1 |
| **473cafb fix reverted** (harness child `cwd: WS`, no `--config`, guard not preloaded) | 3, but **not** the bunfig, node_modules, tsconfig-paths or package-imports tests (finding 1) |
| guard `onLoad` hook made a no-op (`harness.ts`) | **0** (finding 1) |
| `pickWinner` order: smaller artifact before cost | **0** (finding 5) |
| infra spend settled with scope `build` | **0** (finding 2) |
| `FORCE ROW LEVEL SECURITY` dropped on `builds`; RLS dropped on `worker_attempts` | **0 / 0** (finding 4) |

### Test history (tests changed after their red commit)

- `e243018` (p45a red), `1f84021` (red tests for review findings), `c73776e` (p45b red). Later test edits: `724dbd3`
  (`process.env["X"]` index access; the guard emulator's path mapping fixed so `/tmp` is not rewritten twice; the
  Postgres CAP test settles a reservation that the race really granted; the held-out "used" test changed to "used once a
  worker attempt exists" and **strengthened** with a `false` assertion before the attempt row), `d2d2387` (Postgres LOCK
  test gains `BuildEnded` assertions), `683be0b` (an unused parameter renamed). `1f84021` removed only one import line.
- **No assertion was weakened.** The one meaning change (held-out reuse) is in the SPEC's Scope changes in the same
  commit (see finding 6).
- No `.skip`, `.todo` or `.only`. The one skipped test is `LIVE:` Docker (`describe.skipIf(!dockerUp)`), as AGENTS.md
  allows. Postgres tests throw when `DATABASE_URL` is missing instead of passing vacuously, and each file creates and
  drops its own schema and role.
- MIGRATION 5.6 "carry as red tests": all present with their tags except `LOCAL:`, which is handed to m5-03 (finding 7).
  `LOCK: two OKs … exactly one 202` is carried as `GATE: two concurrent OK, build requests…` plus the Postgres `LOCK:`
  race test (finding 10).

### Old fixes from 473cafb (security)

| 473cafb fix | v2 | Test that guards it |
|---|---|---|
| Planted bunfig preload / node_modules / tsconfig paths / package imports / .env cannot fake a PASS | Kept and stronger: `/check` read-only cwd, `--config=/check/bunfig.toml --no-env-file --no-install`, guard preloaded, nonce + JUnit proof (`harness.ts:71-104`, `shards.ts:65-73`) | `.env` and the structural argv test do; the four planted-module tests do **not** (finding 1) |
| Stale lock recovery | Partial unique index + stale `heartbeat_at` recovery in the same transaction (`store-pg.ts:90-108`), `BuildEnded` stops the old orchestrator | yes |
| No orphaned builders | Attempt promises never reject; `Promise.all` before the build ends (`loop.ts:193-260, 282`) | yes |
| Held-out teeth in container mode | One teeth gate for both checks in fresh sandboxes (`loop.ts:177-187`) | yes |
| Budget before spending | Attempt cap reserved before any sandbox (`loop.ts:161-163, 193-195`) | yes |
| No internal paths in stored records | Fixed plain-word notes only | yes (`READY:`) |
| Two concurrent OKs both 202 | Insert under the unique index is the lock | yes |
| Ship twice wiped weeks | `deployed_at` once; `shipOnce` | yes |
| Week measured from the wrong days | `weekMinutes` own days only, × 7 / days stored | yes |

Also checked and correct: approval is exact-hash (four hashes + `cap_usd`), single use, 24 h TTL, `sha256(token)` at
rest with a constant-time compare, kind- and subject-bound, and every hash is compared before anything is written
(`loop.ts:79-81`); the token is never returned, stored or logged (`http.ts:91`, `hardening.test.ts:224`); the held-out
check never reaches builder-facing text (`checks.ts:80-101`, `loop.ts:190, 278`); Docker argv has `--network none`,
`--read-only`, `--cap-drop ALL`, `no-new-privileges`, `--user 65534:65534`, `/check` `readonly` (`docker.ts:129-158`);
an exec error, a timeout or a missing proof is a failed shard (`shards.ts:53-79`); parallel reservations cannot pass
the ceiling (row lock, `store-pg.ts:159-170`); artifact paths are checked with `safeRelPath` and symlinks are not
followed (`provider.ts:76-81`, `docker.ts:103-118`); RLS is `ENABLE` + `FORCE` with `tenant_isolation` on all five
tables (`0001_builder.sql:111-125`); no `console.*` in product code; NOTICE carries superpowers (MIT text included) and
the old branch's idea credits.

### Findings

1. **MAJOR: the planted-file guard tests pass even with the 473cafb fix reverted.**
   Evidence: `guard.test.ts:69` `PAYLOAD` is `afterAll(() => process.exit(0))`, the old exit-code attack. In v2 the
   harness also needs a complete JUnit report with at least one passing test (`harness.ts:88-104`). That payload never
   produces one, so the proof check fails it **whatever the guard does**. Reverting the 473cafb fix
   (`harness.ts:71-74`: child `cwd: WS`, no `--config=/check/bunfig.toml`, no `--no-env-file`) leaves `SHARDS: a
   builder-planted bunfig.toml preload … cannot fake a PASS` (`guard.test.ts:110`) and `SHARDS: … node_modules package,
   tsconfig path or package imports entry is never loaded` (`guard.test.ts:116`) green. Only the `.env` test, the
   structural argv test and the worker-import test fail. Making the guard's `onLoad` hook a no-op fails nothing.
   I confirmed with a scratch test outside the repo that the hole is real. With the fix reverted, a planted
   `bunfig.toml` preloading `const p = Object.getPrototypeOf(expect(0)); for (k of names) if (k.startsWith("to")) p[k] = () => undefined;`
   turns `expect(1).toBe(2)` into a real pass. The shard then **passed** with a valid nonce proof
   (`{"ok":true,"status":"pass","exit":0,"completed":true,"tests":1}`). The current code blocks it (`passed:false`).
   The code is right today, but the regression tests for the main 473cafb security fix are vacuous for 4 of its 5
   vectors (the "control" test at `guard.test.ts:96` proves only the old exit-code attack). The node_modules,
   tsconfig and imports checks import a bare or aliased specifier from `/check`. They fail on "module not found" in any
   layout, so they cannot tell "refused" from "absent".
   Required fix: change `PAYLOAD` (and the control test) to a payload that makes the failing check really pass and lets
   bun write an honest JUnit report (matcher neutering as above, or replacing `test` callbacks). Show that each
   planted-vector test fails with `cwd: WS`/no `--config`, and with the guard preload removed where the vector depends
   on it. For node_modules, tsconfig paths and package imports, add a case where the vector would resolve (for example
   the check importing `/work/node_modules/helper` or a relative path whose tsconfig lives in `/work`). Either test the
   guard's `onLoad` (a symlink or resolution path that reaches `/work` without passing `onResolve`) or say in DESIGN.md
   that it is untested defence in depth.

2. **MAJOR: a sandbox outage during verification is billed to the cap as a check failure, fans out, and tells the user
   the checks failed (ADR 0031).**
   Evidence: `attempt.ts:165` sets `infra` only for errors in the worker sandbox. In `loop.ts:231-247` the
   verification `runShards` results with `error: "infra"` are treated as ordinary failed shards: the attempt becomes
   `fail`, is settled with scope `build` (`loop.ts:253-256`), the build fans out (`loop.ts:277-282`), and the build ends
   `failed` instead of `infra_failed`. Scratch test (outside the repo, `harness([{ spent_usd: 0.5 }])` with
   verification-role `create` throwing `SandboxInfraError` after the worker ran):
   `{"state":"failed","spent_usd4":10000,"workers":2,"entries":[["build",5000],["build",5000]],"last":"No build passed every check. Worker 1: Failed the frozen check and the held-out check in a fresh sandbox. Worker 2: …"}`.
   So $1.00 is billed for Offload's outage, a second worker is started and paid for, the stored note is false, and
   the held-out check is burned (the attempt rows exist). ADR 0031 says provider errors end the build `infra_failed`,
   with that spend under scope `infra`, never billed to the cap. The same happens with the real Docker provider for any
   daemon or image failure: `docker run` exits 125 with no proof (`docker.ts:160-172`) and is never mapped to
   `SandboxInfraError`, so a Docker outage is always a check failure. The `INFRA:` test (`loop.test.ts:279`) only
   covers `create` failing before any spend, which is why the "infra spend settled as `build`" mutation fails nothing.
   Required fix: when any verification shard reports `error: "infra"`, mark the attempt `infra` (outcome `error`,
   settled with scope `infra`), do not fan out, and end the build `infra_failed`. Release the approval only under ADR
   0031's no-model-spend rule. Map Docker CLI failures that are not a check result (exit 125, daemon unreachable,
   spawn failure) to `SandboxInfraError`. Add `INFRA:` tests with a worker spend above 0 and an outage at verification
   (and one during fan-out), asserting state `infra_failed`, no `build`-scope entries for that spend, and no extra worker.

3. **MINOR: a worker's reported spend above its cap is silently cut off in the record.** `attempt.ts:133`
   `r.spent_usd4 = Math.min(i.cap_usd4, …)`. If the WorkerPort (later the egress proxy) reports more than the
   reservation, the ledger and the build's `spent_usd` under-state real money spent. ADR 0030 says the proxy settles
   the *actual* cost. Fix: settle the reported amount as it is (the reservation has already refused new work), end the
   attempt `cap`, and leave enforcement to the proxy (m2-08). Test it with a worker that over-reports.

4. **MINOR: RLS is tested only for `SELECT` on `builds`.** `store-pg.test.ts:128-145`. Dropping `FORCE` on `builds` or
   all RLS on `worker_attempts` fails nothing. The other four tables and the write paths (insert, stale-recovery update,
   reserve, settle) are never run as a non-owner role. Fix: one RLS test that, for all five tables, checks
   `relrowsecurity` and `relforcerowsecurity` and that a cross-tenant read returns zero rows as the non-owner role.
   Ideally also run the `PgBuildStore` lock and cap tests as that role (as `offload_app` will).

5. **MINOR: the winner-order test does not test "cost before size".** `loop.test.ts:117-133`: attempts 2 and 3 cost the
   same, and the cheapest (4) fails held-out, so swapping cost and size in `pickWinner` (`loop.ts:104`) passes. Fix: add
   a passing attempt that is cheaper but larger than another passing attempt and assert that the cheaper one wins. (The
   rule itself still needs the owner to reconcile it with ADR 0029's "smallest diff", DESIGN.md section 6.)

6. **MINOR: the held-out reuse rule is looser than ADR 0029 and DATA_MODEL.** DATA_MODEL `held_out_checks` says "each
   build of a brief gets a fresh one", and ADR 0029 says a retry after `failed` regenerates it. Here a held-out hash
   counts as used only once a worker attempt row exists (`store-pg.ts:110-115`, SPEC Scope changes), so a teeth-failed
   or stale queued build lets the next build reuse it. The reasoning holds (no builder saw anything), and API.md and
   DATA_MODEL were updated. But it changes an ADR's rule, and this stream may not edit `docs/adr/**`. Fix: add an
   owner question (or an OPEN_QUESTIONS entry from the owning stream) to amend ADR 0029. Until then, list it in
   DESIGN.md section 6 as a decision to flag.

7. **MINOR: the `LOCAL:` red tests are tracked only in this slice's DESIGN.md.** MIGRATION 5.6 lists
   `LOCAL: refuses any host that is not loopback` as a mandatory carried red test. It is handed to m5-03
   (`DESIGN.md` section 5, MIGRATION 5.6 note), but the ROADMAP m5-03 row (`docs/ROADMAP.md:435`) does not mention it,
   so it can be lost. Fix: the owner or the m5-03 planner adds the four `LOCAL:` tests and the `redirect: "error"` rule
   to m5-03's SPEC when it is written. Record this in the hand-off so it is not lost; ROADMAP is outside this slice's
   scope.

8. **MINOR: no network isolation or registry check runs anywhere.** SECURITY_PRIVACY section 13 ("outbound connection
   to a non-allowlisted host fails; no registry reachable") is covered only by the `LIVE:` Docker test
   (`docker.test.ts:144`), which has never run (DESIGN.md section 7). The argv test pins `--network none`, which is
   good, but no test shows it. Fix: run the `LIVE:` test once on a machine with Docker before m2-08 relies on it, and
   add a registry fetch to it. Also pin the entrypoint (`--entrypoint bun`, or check that `oven/bun`'s entrypoint
   `exec`s), because the `kill(-1)` sweep (`harness.ts:82-87`) only runs when the harness is PID 1. Consider making
   `parseProof` require `swept: true` for verification shards.

9. **MINOR: a deploy that fails after the routine was created can create a second routine.** `http.ts:128-138`: any
   error from `routines.deploy` clears `deployed_at`, including a timeout after the runtime already created the
   version. Fix: pass an idempotency key (`build_id`) to `RoutinePort.deploy`, and note in DESIGN.md section 4 that m2-09
   must honour it.

10. **NIT:** MIGRATION's `LOCK: two OKs of the same brief at once…` is tagged `GATE:` in `http.test.ts:67`. Rename it to
    `LOCK:` so a grep for the carried name finds it. `services/builder/sql/0001_builder.sql` creates its own
    `budget_entries`, the shared ledger of DATA_MODEL section 8 (scopes `design`, `run`, `brain`). When `packages/db`
    lands it, keep one definition; DESIGN.md section 4 should say so explicitly.

p45b (`packages/hours-saved/src/measured/`): no findings above NIT. The thresholds are integer tenths on the unrounded
median (`outcome.ts:108-118`); weeks are measured once, at their end, from their own days; purged weeks are never
guessed; Figures carry arithmetic, evidence, `source_purged_at` and stable `fig_` ids; the package root gains type
exports only.

**Required before PASS:** fix findings 1 and 2 with red-first tests (show them failing against the current code, or
against the reverted fix for finding 1). The MINORs can be fixed or recorded in DESIGN.md section 7 with an owner.

VERDICT: CHANGES
