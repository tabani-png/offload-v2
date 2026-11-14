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

### Author response (round 1)

Commits `18499c8..3505309`, red tests before every behaviour change. After them: p45a slice suite **110 tests (109
pass, 1 skip `LIVE:`)**, up from 98; p45b **17** (unchanged); full suite **177 tests across 34 files, 176 pass, 1
skip**; both `verify.sh` PASS; `scripts/verify-all.sh` green. Each mutation below was run on a copy in `/tmp`, never
in the repo.

1. **MAJOR, fixed (tests).** The payload now neuters every matcher, so a loaded worker module makes a failing check
   really pass with an honest JUnit report. The control test shows that (exit 0, 1 test, 0 failures).
   - **Path vectors** (`../work/evil.ts`, `../work/node_modules/helper[/index.js]`, worker code imported by mistake)
     assert the guard's refusal message.
   - **Bare, tsconfig-paths and package-imports specifiers from `/check`** assert they do not resolve: from outside the
     workspace they cannot (layout protection).
   - **A new direct guard test** covers the `onLoad` hook: a `node_modules` symlink, a tsconfig alias and an absolute
     path into the workspace. Each has a no-guard control that passes.
   - **Mutation results:**

     | Mutation | Tests that now fail |
     |---|---|
     | 473cafb fix reverted (`cwd: WS`, no `--config`, no `--no-env-file`) | 4, including the bunfig and path tests |
     | guard preload removed | 6 |
     | `onLoad` registration deleted | 2 |

     The `onLoad` deletion is the honest mutation: returning `undefined` from `onLoad` is itself a Bun error. DESIGN.md
     section 7 calls `onLoad` defence in depth. (`18499c8`)
2. **MAJOR, fixed.**
   - A verification shard with `error: "infra"` makes the attempt an infra error: outcome `error`, spend settled with
     scope `infra`, no fan-out, build `infra_failed`.
   - Any infra attempt without a winner ends `infra_failed`.
   - The approval is released only when no model money was settled under any scope (ADR 0031).
   - The Docker provider maps a CLI that cannot run, and `docker run` exits 125 to 127, to `SandboxInfraError`.
   - New tests:
     - `INFRA:` an outage at verification after $0.50 of worker spend (state `infra_failed`, no `build` entries, one
       `infra` entry of 5 000, one worker, approval not released);
     - `INFRA:` an outage while the fan-out worker is verified (`build` 3 000 for worker 1, `infra` 4 000 for worker 2);
     - `SANDBOX:` exit 125, 126, 127 and spawn failure are infra; exit 1 is a check result.
   - (`e30bd85`, red `b2b03a2`)
3. **MINOR, fixed.** Reported spend is settled as it is. Reaching the cap still ends the tries, and the reservation
   refuses new work. New test: a worker reporting $1.00 against a $0.70 cap gets 1 try, outcome `cap`, ledger 10 000.
   (`4723ddf`, red `6c91b60`)
4. **MINOR, fixed (tests).**
   - All five tables are checked for RLS enabled and forced.
   - The store is run through a pool connected as a non-owner `NOBYPASSRLS` role, with SELECT, INSERT and UPDATE only.
   - As that role:
     - another tenant's rows (and rows with no tenant set) are invisible in all five tables;
     - a cross-tenant update changes nothing;
     - the lock race and stale recovery hold;
     - three parallel reservations cannot pass the ceiling;
     - deleting budget entries is refused.
   - Fails with `FORCE` dropped on `builds` (1) and with RLS dropped on `worker_attempts` (2). (`164b8b9`)
5. **MINOR, fixed (test).** A cheaper but larger passing attempt wins, plus direct `pickWinner` cases. Fails with size
   and cost swapped. The rule itself stays an owner question (DESIGN.md section 6). (`29f25af`)
6. **MINOR, recorded.** This stream may not edit ADRs or OPEN_QUESTIONS, so DESIGN.md section 6 lists held-out reuse
   as an owner question: amend ADR 0029, or tighten `heldOutUsed` to "any build" (one query). (`3505309`)
7. **MINOR, recorded.** DESIGN.md section 7 names the owner action: whoever writes m5-03's SPEC adds the four
   `LOCAL:` tests and `redirect: "error"`. ROADMAP is outside this slice's scope. (`3505309`)
8. **MINOR, partly fixed.**
   - **Fixed:**
     - the Docker argv pins `--entrypoint <argv[0]>`, so the harness is PID 1;
     - `parseProof` reports `swept`;
     - the `LIVE:` test also tries a package registry and asserts `swept: true`.
   - **Not done, with reason:** the `LIVE:` test still has not run (no Docker on this box). Requiring `swept` for
     verification shards would break the emulated guard tests (the emulator is not PID 1). Both are in DESIGN.md
     section 7: run LIVE once on a Docker host before m2-08, then require `swept`.
   - (`0e7a3ed`, red `e20687d`; `3505309`)
9. **MINOR, fixed.** `RoutinePort.deploy` gets `idempotency_key = deploy:<build_id>`, the same on every retry. New
   `SHIP:` test: a deploy that fails after the routine was created, then a retry; both calls carry the same key. DESIGN.md
   section 4 says m2-09 must honour it. (`84785f0`, red `33a88f0`)
10. **NIT, fixed.** The carried test is now `LOCK: two OKs of the same brief at once: exactly one 202, the other 409
    already_running`. DESIGN.md section 4 says `budget_entries` must end up as one definition when `packages/db` lands
    it. (`3505309`)

## Round 2

Independent review (Opus 5.5, wrote neither the code nor round 1), 2026-11-14, branch `port/build-loop` at `88cbc89`,
diff `8f6ff2d..88cbc89`.

**Read:**
- AGENTS.md and CLAUDE.md;
- both SPECs, DESIGN.md, and round 1 with its author response;
- ADR 0011, 0012, 0029, 0030 and 0031;
- DATA_MODEL sections 1, 6 and 8, and the API.md builds rows;
- SECURITY_PRIVACY section 13 and MIGRATION 5.6;
- every source file in the diff;
- `git log -p` on both test folders from each red commit on;
- the old `473cafb` commit message, and the test names in its hardening tests (`/workspace/offload-wsC`, read only).

### Runs (this reviewer, DATABASE_URL set)

| Command | Result |
|---|---|
| `bash scripts/verify-all.sh` | `verify-all: green`. Full suite **177 tests across 34 files: 176 pass, 1 skip (`LIVE:` Docker), 0 fail**. Both done slices PASS. slices, doc links, copy, secrets and workflows all ok |
| `bash slices/p45a-build-loop/verify.sh` | `p45a-build-loop: PASS`. Slice suite **110 tests across 10 files: 109 pass, 1 skip, 0 fail** (min 75). All 24 tags are present and passing. Scope checked (47 files) |
| `bash slices/p45b-measured-saving/verify.sh` | `p45b-measured-saving: PASS`. Slice suite **17 tests across 1 file: 17 pass** (min 12). All 6 tags passing. Scope checked (32 files) |
| Scope | Nothing changed under `packages/{db,contracts,policy,testkit,routine-sdk,connectors-sdk}`, `services/{api,runtime,broker,brain}`, `apps`, `ee`, `.github` or `docs/adr`. `bun.lock` and `package.json` are unchanged. Each `verify.sh` differs from the template only in the header comment and the allowed variables. NOTICE carries superpowers (full MIT text), craft-anything, apple/container, container-use, CompanyOS (ideas only) and exo |

### Mutation checks (tests really fail without the code)

How I ran them:
- A script in `/tmp` (outside the repo) applied each mutation with `perl -0pi`.
- It ran both slice suites (126 runnable tests), then restored the file with `git checkout --`.
- Afterwards `git status` was clean. No stash was used.

| Mutation | Failing tests |
|---|---|
| verification-shard infra branch off (`loop.ts:235`) | 2 (`INFRA:` after spend, fan-out) |
| Docker exit 125 to 127 not mapped to infra (`docker.ts:177`) | 1 (`SANDBOX:`) |
| worker spend clamped to the cap again (`attempt.ts:134`) | 1 (`BUDGET:`) |
| approval released even after model spend (`loop.ts:174`) | 1 (`INFRA:`) |
| attempt spend always settled as `build` (`loop.ts:267`) | 2 (`INFRA:`) |
| "no winner + an infra attempt" branch off (`loop.ts:303`) | 1 (`INFRA:` fan-out) |
| shard `SandboxInfraError` reported as `exec` (`shards.ts:245`) | 4 (`SANDBOX:`, 3 `INFRA:`) |
| infra entries counted toward `spent_usd`: memory store / Postgres store | 2 / 1 (`BUDGET: (Postgres)`) |
| **473cafb fix reverted** (`cwd: WS`, no `--config`, no `--no-env-file`; `harness.ts:72-74`) | **4** (`SHARDS:` bunfig, path vectors, worker import, layout) |
| guard `onLoad` registration removed (`harness.ts:302`) | 2 |
| guard `onResolve` refusal made a no-op (`harness.ts:296`) | **0** (finding 6) |
| `--entrypoint` unpinned (`docker.ts:157`) | 1 (`SANDBOX:` argv) |
| `heldOutUsed` always false: memory store / Postgres store | 2 / 1 (`HELDOUT:`) |
| deploy idempotency key differs per call (`http.ts:132`) | 1 (`SHIP:`) |
| approval TTL check off (`approvals.ts:114`) | 2 (`GATE:`) |
| teeth gate's workspace-write check off (`loop.ts:187`) | 1 (`TEETH:`) |

Every round 1 fix is now pinned by a test that fails without it.

### Test history (tests changed after their red commit)

**Red commits:**
- `e243018` (p45a);
- `1f84021` (round-0 findings);
- `c73776e` (p45b);
- `b2b03a2`, `6c91b60`, `e20687d`, `33a88f0` (round 1).

**Later test edits:**
- `724dbd3` (green):
  - `process.env["X"]`;
  - an emulator path-mapping fix;
  - the Postgres CAP test settles the reservation the race really granted;
  - **the `HELDOUT: (Postgres)` assertion was flipped from `true` to `false` for a queued build** (finding 1).
- `d2d2387`: `BuildEnded` assertions added (stronger).
- `683be0b`: a parameter rename.
- `18499c8` (guard tests):
  - The control and bunfig tests are stronger: an honest JUnit report, and `nonce_ok`, `status` and `tests` asserted.
  - The old mixed loop was split into path vectors (which now assert the refusal message) and bare specifiers.
  - `/work/evil.ts` moved to the direct `onLoad` test (absolute path), which has a no-guard control.
  - Nothing weaker.
- `164b8b9`: the one-table RLS test was replaced by five-table and non-owner-role tests. They are stronger, but see
  finding 7.
- `29f25af`: additions only.
- `e20687d`: the argv pin was updated for `--entrypoint` (stricter).
- `3505309`: a rename only.

**Other checks:**
- No `.skip`, `.todo`, `.only` or `it(`. The one skip is `describe.skipIf(!dockerUp)` for `LIVE:`.
- The Postgres tests throw without `DATABASE_URL`, and create and drop their own schema and role.
- The MIGRATION 5.6 carry list is all present with its tags, except `LOCAL:`, which is handed to m5-03 (round 1
  finding 7, still an owner action).
- SECURITY section 13 builder rows: approval (wrong hash 403, used, expired as `approval_expired` at the port; an
  HTTP 409 for expiry belongs to m2-06's approvals), deploy `definition_hash` 403, tamper, fake pass, teeth,
  credentials and env, and three parallel reservations all have tests. **"outbound connection fails; no registry
  reachable" still exists only as the never-run `LIVE:` test** (round 1 finding 8, recorded in DESIGN.md section 7).

### Old fixes from 473cafb (re-checked against its commit message)

| 473cafb fix | v2 |
|---|---|
| guarded bun shards (bunfig, node_modules, tsconfig paths, package imports, .env) | Kept. The reverted-fix mutation now fails 4 tests |
| recoverable stale lock (two recoverers) | Kept: a partial unique index plus stale recovery in one transaction. `LOCK: (Postgres)` tests run as owner and as a non-owner role |
| no orphaned builders | Kept (`FANOUT:` mint failure and throw tests) |
| no fan-out after an early gate | Kept |
| held-out teeth in containers | Kept |
| budget before spending | Kept |
| no internal paths in records | Kept |
| two concurrent OKs | Kept |
| ship twice wiped weeks | Kept |
| per-week measurement | Kept |

The unreadable-lock-file case does not apply: the lock is a row.

Also re-checked and correct:
- **Approvals:** exact hashes plus `cap_usd`, single use, 24 h TTL, `sha256(token)` with a constant-time compare, bound
  to `kind` and subject. All compared before any write (`loop.ts:79-81`, `http.ts:126`).
- **Held-out isolation:** the held-out check never reaches BUILD.md, the worker files, the prompt or fan-out feedback
  (only "the held-out check also failed").
- **Docker argv:** `--network none`, `--read-only`, `--cap-drop ALL`, `no-new-privileges`, `--user 65534:65534`, `/check`
  read-only, `--entrypoint` pinned.
- **Failures never pass:** an exec error, a timeout or a missing proof is a FAIL. A provider outage is `infra`, never a
  pass and never billed.
- **Budget:** reservations under a row lock cannot pass the ceiling, including fan-out.
- **Artifact paths:** they go through `safeRelPath`, and symlinks are skipped.
- **No leaks:** no `console.*`, and no token in responses or rows.
- **RLS:** `ENABLE` + `FORCE` on all five tables. The builder tables are not MI tables in DATA_MODEL section 6, so no
  `member_isolation` is due.
- **p45b:** sound. Integer-tenths thresholds on the unrounded median; weeks measured once, at their end, from their own
  days; purged weeks never guessed; Figures with stable `fig_` ids; the package root has type exports only.

### Round 1 findings, status

| Finding | Status |
|---|---|
| 1, 2, 3, 4, 5, 9, 10 | Fixed with tests; my mutations confirm each |
| 6 (held-out reuse) | Not resolved: escalated as finding 1 below |
| 7 (`LOCAL:` hand-off) | Recorded as owner actions in DESIGN.md section 7; unchanged |
| 8 (`LIVE:` network and registry run) | Recorded as an owner action in DESIGN.md section 7; unchanged |
| winner-order question | Recorded as an owner question in DESIGN.md section 6; unchanged |

### Findings

1. **BLOCKER: a red-test assertion was weakened in the green commit, and the code now allows held-out reuse that ADR
   0029 forbids.**
   - Evidence:
     - In red `e243018`, `store-pg.test.ts` asserted
       `expect(await store.heldOutUsed(TENANT, "brief_held", …)).toBe(true)` straight after `insertQueued`. That is ADR
       0029's rule ("A new build of the same brief regenerates the held-out check") and DATA_MODEL `held_out_checks`
       ("each build of a brief gets a fresh one").
     - Green `724dbd3` changed the same assertion to `.toBe(false)` (`store-pg.test.ts:123`).
     - It also implemented "used only once a worker attempt row exists" (`store.ts:297-303`, `store-pg.ts:110-115`).
     - The hardening test `LOCK: a build with no progress … ended infra_failed by the next OK, which then starts`
       (`hardening.test.ts:19`) now relies on reusing the same held-out hash.
   - The change is written up in SPEC "Scope changes" and in DESIGN.md section 6 as an owner question. I found no
     practical leak: no builder sees held-out bytes or results before an attempt row exists, and attempts beat the
     heartbeat before every turn.
   - But it relaxes a security rule of an accepted ADR that this stream may not edit, without the owner's decision.
     Round 1 rated it MINOR and said no assertion was weakened; I disagree on that point. This review's rule is that a
     weakened assertion is a BLOCKER.
   - Required fix, one of:
     - (a) Restore the red assertion: any build of the brief bound to the hash makes it used. That is one query in each
       store. Update the stale-recovery tests to bring a fresh held-out, as `hardening.test.ts:32` already does.
     - (b) The owner amends ADR 0029 to allow reuse when no worker started. Cite that decision in the SPEC, and keep
       the current test.

2. **MINOR: two starts of one build end it `failed` and burn the user's single-use OK before any work.**
   - Evidence:
     - `runBuildInner` reads `state = queued` (`loop.ts:122-123`) and only then claims the approval (`loop.ts:144`).
     - A second start that read `queued` in the same window gets `approval_used`. It then writes `failed` over the live
       build (`loop.ts:145-149`), and the first orchestrator stops at its next save with `BuildEnded`.
   - Scratch test outside the repo: two `runBuild` calls for one build gave
     `{"state":"failed","last":"The OK, build approval was already used.","worker_turns":0,"sandboxes":0}`.
   - The inline runner starts each build once today. A durable adapter that re-runs the workflow after a crash
     (W1-C) would hit this and end the build `failed` instead of `infra_failed` (ADR 0031: orchestrator crash).
   - Required fix:
     - make "start" a compare-and-set in the store (`queued` → `building`, with the claim); the loser returns without
       writing;
     - add a `LOCK:` test with two concurrent `runBuild` calls;
     - note in DESIGN.md section 4 that the durable adapter must not re-enter `runBuild` after the claim.

3. **MINOR: ADR 0031's retry path is not built and not recorded, and a zero-spend outage still burns the held-out
   check.**
   - Evidence:
     - `POST /v1/builds/{id}/retry` (API.md:187), the automatic retries (3 within an hour) and `infra_retries` (never
       written: `store.ts:157` and `store-pg.ts:130` only round-trip it) are missing.
     - None of them is in SPEC "Out of scope" or DESIGN.md section 7.
     - So `release()` (`loop.ts:173-175`) has no effect: the released approval is bound to this build's id, and
       `runBuild` only runs `queued` builds.
     - The attempt row is written before the worker sandbox exists (`loop.ts:214`). A worker-sandbox outage with no
       spend therefore marks the held-out check used.
   - Scratch test: `{"state":"infra_failed","spent":0,"released":true,"worker_turns":0,"heldOutUsed":true,"nextOk":"state_conflict"}`.
     The user must re-review and pay a new held-out check for Offload's outage. ADR 0031 says a no-spend retry needs no
     new OK.
   - Required fix:
     - list the retry endpoint, the automatic retries and `infra_retries` in SPEC "Out of scope" or DESIGN.md section 7,
       with an owner;
     - and either count the held-out check as used only once a worker turn starts, or say in DESIGN.md that a pre-turn
       outage burns it.

4. **MINOR: the verification image is a mutable tag and `docker run` may pull it.**
   - Evidence:
     - `config.ts:353` is `image: "oven/bun:1.4.4"`, not a digest.
     - `runArgv` (`docker.ts:136-160`) has no `--pull=never`, so `docker run` uses its default `--pull=missing` and
       fetches from a registry at verification time.
   - The harness that gives the verdict runs `bun` from that image, so whoever controls the tag controls the verdicts.
     ADR 0011 says workers run on prebuilt images with a pinned dependency set.
   - Required fix: add `--pull=never` to the argv, pinned by the argv test. Then either refuse a verification image
     without `@sha256:` outside tests, or record the pin as a spike S4 / m2-08 gap in DESIGN.md section 7. Neither is
     recorded today.

5. **NIT: a stale-recovered build's in-flight worker spend is billed as `build`.** `reserve`, `putAttempt` and `settle`
   do not check that the build is live. A worker whose turn outlives the stale limit ends with `BuildEnded`, caught as
   outcome `error` (`attempt.ts:164-167`). Its spend is then settled with scope `build` on an `infra_failed` build
   (`loop.ts:267`). ADR 0031 calls that infra spend. This only happens when a turn runs past 34 minutes. Map
   `BuildEnded` to `infra` in `runAttempt`.

6. **NIT: the guard's `onResolve` refusal is not pinned.** Making it a no-op (`harness.ts:296`) fails 0 tests, because
   `onLoad` stops the same loads. Either pin it with a test, or drop it and say so in DESIGN.md section 7.

7. **NIT: the cross-tenant UPDATE assertion is vacuous.** `store-pg.test.ts:162-169` reads the row back under
   `OTHER_TENANT`, so the count is 0 whatever the UPDATE did. Read it as `TENANT` and assert the state is still `ready`.

8. **NIT: the teeth gate's write check sees regular files only.** `snapshot` uses `getFiles`, which skips symlinks and
   lists no directories (`docker.ts:104-127`). A check that only creates a symlink or an empty folder in `/work` passes
   "leaves the workspace unchanged". Include directories and symlink entries in the snapshot.

**Required before PASS:** resolve finding 1, by (a) or (b). Fix or record findings 2 to 4 (record with an owner in
DESIGN.md section 7). Findings 5 to 8 are optional. The round 1 owner actions stay open: the `LIVE:` Docker run, the
`LOCAL:` tests for m5-03, and the winner order.

VERDICT: CHANGES
