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

### Author response (round 2)

Commits `4733412..db02790`; behaviour changes had a red test committed first. After them:
- p45a slice suite **116 tests (115 pass, 1 skip `LIVE:`)**, up from 110;
- p45b **17** (unchanged);
- full suite **183 tests across 34 files, 182 pass, 1 skip**;
- both `verify.sh` PASS; `scripts/verify-all.sh` green.

Mutations were run on copies in `/tmp`, never in the repo.

1. **BLOCKER, fixed by option (a).**
   - The red-commit assertion is restored word for word: `HELDOUT: (Postgres) a held-out hash used by a build of the
     brief is remembered` expects `true` straight after `insertQueued`.
   - The ADR 0029 rule is back: any build of the brief bound to a held-out hash uses it.
   - The check lives in `insertQueued`, in the lock's transaction:
     - after the live-build check, so a running build still answers `409 already_running`;
     - before any stale recovery, so a refusal (`HeldOutUsed`, mapped to `409 state_conflict`) recovers nothing.
   - The separate pre-check in `okBuild` is gone, and `heldOutUsed` drops the worker-attempt condition.
   - New tests:
     - `HELDOUT:` after stale recovery the same hash is refused and the stale build is left queued, then a fresh
       held-out recovers it (memory);
     - the same, against Postgres.
   - Fixture changes, not weakened assertions:
     - three tests that start a second build of a brief now bring a fresh held-out check, as ADR 0029 requires (two
       stale-recovery tests and the failed-mint test);
     - the Postgres `newBuild` fixture gives every build its own held-out hash.
   - SPEC Scope changes, DESIGN section 6, API.md and DATA_MODEL.md now state the ADR rule.
   - (`3606861`, red `4733412`)
2. **MINOR, fixed.**
   - `BuildStore.startBuild` is a compare-and-set from `queued` to `building` (Postgres also requires a recorded
     approval). `runBuild` calls it before claiming; the loser returns without claiming or writing.
   - New tests: `LOCK:` two concurrent `runBuild` calls (ready, one worker turn, one teeth gate), and a Postgres race on
     `startBuild`.
   - The Postgres test gained a "no approval yet means no start" assertion in the green commit (stronger).
   - DESIGN section 4 says the durable adapter must not re-enter `runBuild` after the claim.
   - (`3cd80ce`, red `ee46496`)
3. **MINOR, recorded.**
   - The retry endpoint, the automatic retries and `infra_retries` are in SPEC "Out of scope" and DESIGN section 7,
     with owner m2-08. `release()` only marks the approval for that endpoint.
   - Under the restored rule (finding 1), a new build after any `infra_failed` needs a new held-out check, even with no
     worker turn. That matches ADR 0029 and is stated in DESIGN sections 6 and 7. Retrying the same build (m2-08)
     keeps its check. (`db02790`)
4. **MINOR, fixed and recorded.**
   - `docker run` gets `--pull never`, pinned by the exact-argv test (`01166bd`, red `c8917f0`).
   - The digest pin (and then refusing non-digest images in config) is recorded in SPEC "Out of scope" and DESIGN
     section 7, with owners spike S4 and m2-08. (`db02790`)
5. **NIT, fixed.**
   - `runAttempt` maps `BuildEnded` to infra, and so does the build loop when the beat before verification throws it.
   - The stale-orchestrator test now asserts the old build's entries are all `infra` and its `spent_usd` is 0.
   - (`7c17864`, red `2be55dd`)
6. **NIT, fixed (test).**
   - New test: a path into the workspace is refused at resolution. The refusal comes from the `onResolve` throw site.
     It fails with `onResolve` removed; `onLoad` keeps its own test.
   - Probing also showed that JSON and text imports from `/work` pass both hooks. That is data, not code, and is now
     stated in DESIGN section 7.
   - (`01915f8`)
7. **NIT, fixed (test).** The cross-tenant `UPDATE … RETURNING` must return no row, and the build read back as its
   own tenant is still `ready`. (`0db4c7b`)
8. **NIT, fixed.**
   - The Docker provider's `snapshot` lists folders (empty ones too), symlinks with their target and other entries, as
     well as files.
   - New `SANDBOX:` test: an empty folder or a symlink created by a check changes the snapshot, and the artifact still
     carries neither.
   - (`5149710`, red `c0c3dd7`)

Still open owner actions (unchanged): the `LIVE:` Docker run, the `LOCAL:` tests for m5-03, and the winner order.

## Round 3

Independent review (Opus 5.5; wrote none of the code, round 1 or round 2), 2026-11-14, branch `port/build-loop` at
`3321961`, diff `8f6ff2d..3321961`.

**Read:**
- AGENTS.md and CLAUDE.md;
- both SPECs, DESIGN.md, and rounds 1 and 2 with their author responses;
- ADR 0011, 0012, 0029, 0030 and 0031;
- DATA_MODEL sections 1, 6 and 8, and the API.md builds rows;
- SECURITY_PRIVACY section 13 and MIGRATION 5.6 (with its carry list);
- every source file in the diff, and the tests;
- `git log -p` on both test folders for every commit after round 2 (`4733412..3321961`), and the removed lines of every
  earlier test commit;
- the `473cafb` commit message in `/workspace/offload-wsC` (read only).

### Runs (this reviewer, DATABASE_URL set)

| Command | Result |
|---|---|
| `bash scripts/verify-all.sh` | `verify-all: green`. Full suite **183 tests across 34 files: 182 pass, 1 skip (`LIVE:` Docker), 0 fail**. p45a and p45b both PASS. Slices (10 specs), doc links (70 files), copy, secrets and workflows are ok, and the license boundary holds |
| `bash slices/p45a-build-loop/verify.sh` | `p45a-build-loop: PASS`. Slice suite **116 tests across 10 files: 115 pass, 1 skip, 0 fail** (min 75). All 24 tags pass: GATE 11, CHECKS 4, HELDOUT 11, TEETH 4, DEFAULT1 1, SHARDS 18, FANOUT 9, STALL 2, LOCK 13, SHIP 4, BUDGET 5, CAP 3, TAMPER 1, PROOF 2, VERDICT 1, SANDBOX 10, INFRA 3, DEPLOY 1, READY 3, TDD 2, STEPS 1, ERROR 1, API 3, RLS 2. The full suite (183) passes. Scope checked (47 files) |
| `bash slices/p45b-measured-saving/verify.sh` | `p45b-measured-saving: PASS`. Slice suite **17 tests across 1 file: 17 pass** (min 12). SHIP 3, MEASURE 6, FLAG 2, MONTH 1, OUTCOME 2, FIGURE 3. The full suite (183) passes. Scope checked (32 files) |
| Both slice folders together | 133 tests: 132 pass, 1 skip |
| Scope | Every changed file matches `paths_in_scope`. Nothing changed under `packages/{db,contracts,policy,testkit,routine-sdk,connectors-sdk}`, `services/{api,runtime,broker,brain}`, `apps`, `ee`, `.github` or `docs/adr`. `bun.lock` and `package.json` are unchanged. Each `verify.sh` differs from the template only in its header and the four allowed variables. `packages/hours-saved/src/index.ts` gains type exports only. NOTICE carries superpowers (with the full MIT text), craft-anything, apple/container, container-use, exo and CompanyOS (ideas only) |
| Postgres hygiene | Each file makes its own `p45a_<suffix>` schema and `NOBYPASSRLS` role and drops them. After the runs, no `p45a_%` schema or role was left |

### Mutation checks (tests really fail without the code)

How I ran them:
- A script in `/tmp/r3-mut` (outside the repo) applied each mutation with `perl -0pi` and checked that the file changed.
- It ran both slice folders (133 tests), then restored the file with `git checkout --`.
- No stash was used. `git status` was clean afterwards.

**New in this round: mutations that fail tests**

| Mutation | Failing tests |
|---|---|
| held-out reuse check removed from `insertQueued` (memory `store.ts:162` / Postgres `store-pg.ts:96`) | 2 / 1 (`HELDOUT:`) |
| `startBuild` compare-and-set always wins (`store.ts:232`) / the loop ignores its result (`loop.ts:144`) | 1 / 1 (`LOCK: two starts…`) |
| `--pull never` removed (`docker.ts:243`) | 1 (`SANDBOX:` exact argv) |
| snapshot ignores folders and symlinks (`docker.ts:216-218`) | 1 (`SANDBOX:` snapshot) |
| loop's `BuildEnded` → infra removed (`loop.ts:265`) | 1 (`LOCK:` stale orchestrator) |
| derived approval minted from an unclaimed parent (`approvals.ts:256`) / released twice (`approvals.ts:301`) | 1 / 1 (`GATE:`) |
| `putFiles` path check removed (`docker.ts:176`) / shard artifact path check removed (`shards.ts:157`) | 1 / 1 |
| `getFiles` follows symlinks (`docker.ts:192-193`) | 2 |
| computed import allowed (`checks.ts:67`) / the held-out writer's prompt gets the visible body (`heldout.ts:258`) | 1 / 1 |
| `FORCE` RLS dropped on `budget_entries` / RLS dropped on `budget_reservations` (SQL) | 1 / 2 (`RLS:`) |

**Repeated from earlier rounds (still fail)**

| Mutation | Failing tests |
|---|---|
| **473cafb reverted**: child `cwd: WS`, no `--config`, no `--no-env-file` (`harness.ts:72-74`) | 4 (`SHARDS:`) |
| guard preload removed from the shard bunfig (`harness.ts:20`) | 7 |
| `--network none` dropped / `/check` mounted read-write | 1 / 2 |
| shard pass = exit 0 only / an exec error counted as a pass (`shards.ts`) | 2 / 3 |
| reservation ceiling off (memory) / `FOR UPDATE` dropped (Postgres) | 1 / 2 (`CAP:`) |
| `parseProof` without `tests >= 1` | 1 (`PROOF:`) |

**Mutations that fail nothing (finding 2)**

| Mutation | Failing tests |
|---|---|
| teeth gate's "could not run" stop removed (`loop.ts:191`) | **0** |
| tamper check before the first try removed (`attempt.ts:113-117`) | **0** |
| `runAttempt`'s `BuildEnded` → infra removed (`attempt.ts:168`) | **0** |
| approval claim key-count check removed (`approvals.ts:244`) | **0** |
| harness `--no-install` removed | **0** |
| harness `completed` without `tests >= 1` (`harness.ts:98`) | **0** |
| artifact size limits removed (`docker.ts:196`) | **0** |
| docker CLI gets the whole host environment (`docker.ts:103`) | **0** |
| `feedbackText` keeps `OFFLOAD_PROOF` lines (`attempt.ts:87`) | **0** |

### Test history (tests changed after their red commit)

**Since round 2:**
- `4733412` (red):
  - The Postgres `HELDOUT:` assertion is restored to the red commit's `toBe(true)` straight after `insertQueued`.
  - The `putAttempt` step and the `false` assertion it guarded are gone. Both belonged to the loosened rule that round 2
    rejected, so this is the BLOCKER fix, not a weakening.
  - Three tests now bring a fresh held-out check for a second build of a brief. This is a fixture change that ADR 0029
    requires; no assertion was removed.
- `3cd80ce` (green): adds a "no approval, no start" assertion. Stronger.
- `0db4c7b`: the vacuous cross-tenant read-back is replaced by `RETURNING` (no row) plus a read as the owning tenant
  (`ready`). Stronger.
- `ee46496`, `c8917f0`, `2be55dd`, `01915f8`, `c0c3dd7`: additions only.

**Earlier commits:** I re-read every removed `expect`/`test(` line, from `e243018` to `3505309`. They were renamed,
moved or replaced by stricter ones (`process.env["X"]`, the guard payload, the five-table RLS test, the argv pin,
`LOCK:` rename). The one flip (`724dbd3`) was restored in `4733412`. **No assertion is weakened in the current tree.**

**Other checks:**
- No `.skip`, `.todo`, `.only` or `it(`. The one skip is `describe.skipIf(!dockerUp)` for `LIVE:` (`docker.test.ts:176`).
- The Postgres tests throw without `DATABASE_URL`.
- MIGRATION 5.6 carry list: every name is present with its tag, except two:
  - `LOCAL:` is handed to m5-03 (owner action, see finding 5).
  - `GATE: a wrong brief hash…` is covered under another name (finding 7).
- SECURITY section 13 builder rows: each has a test. "Outbound connection fails; no registry reachable" exists only as
  the never-run `LIVE:` test.

### Old fixes from 473cafb

I re-checked every fix against the commit message:
- guarded bun shards;
- stale lock recovery (two recoverers);
- no orphaned builders;
- no fan-out after an early gate;
- held-out teeth in containers;
- budget before spending;
- no internal paths in records;
- two concurrent OKs;
- ship twice;
- per-week measurement.

All are kept, and the mutations above pin the security ones. "Check writers paid before the budget check" moves to
m2-05 (design budget).

### Round 2 findings, status

| Finding | Status |
|---|---|
| 1 BLOCKER (held-out reuse) | Fixed: ADR 0029's rule is back in both stores, inside the lock's transaction. My mutations fail 2 + 1 tests |
| 2 (two starts) | Fixed: a compare-and-set start. My mutations fail 1 test each (see NIT 10 on its order) |
| 3 (ADR 0031 retry path) | Recorded: SPEC "Out of scope" and DESIGN section 7, owner m2-08 |
| 4 (image pull) | `--pull never` is pinned. The digest pin is recorded (spike S4, m2-08) |
| 5 (`BuildEnded` spend) | Half pinned: the loop's path is tested, `runAttempt`'s is not (finding 2) |
| 6, 7, 8 | Fixed |

### Findings

1. **MAJOR: the built tool can read the held-out check during verification and pass it without doing the work. This
   fakes the held-out verdict that ADR 0012 and ADR 0029 rest on.**
   - Evidence:
     - Check files are written `0444` in a `0755` folder (`docker.ts:148, 179-181`) and mounted at `/check`
       (`docker.ts:256`).
     - The harness, `bun test` and the tool it spawns all run as uid 65534 (`docker.ts:250`).
     - `bun test`'s argv names the check file (`harness.ts:72`).
     - So the artifact can open `/check/accept.test.ts` directly, or find it through `/proc/<ppid>/cmdline`, and print
       the values the check expects.
     - The worker can build and test that trick in its own sandbox: the frozen check sits at the same path there
       (`attempt.ts:104-108`), and BUILD.md tells it that other checks it does not see also decide the result
       (`checks.ts:99`).
   - Scratch test (outside the repo, `/tmp/r3-scratch`, using the same emulated `docker run` as `guard.test.ts` and the
     real `runShards`):
     - The held-out check expects `zq-7781-unguessable` from `tool.ts edge`.
     - An honest tool that does not know the answer fails: `{"passed":false,"proof":{"ok":false,"status":"fail",…}}`.
     - A tool that reads the check through its parent's argv and prints the `toBe("…")` literal passes:
       `{"passed":true,"proof":{"ok":true,"nonce_ok":true,"status":"pass","exit":0,"completed":true,"tests":1}}`.
     - In real Docker it is simpler still: `readFileSync("/check/accept.test.ts")`.
   - This needs no ptrace and no nonce. DESIGN.md section 7's "same uid" item covers only the nonce through ptrace.
     Its planned fix (run `bun test` as 65534) would not close this hole, because `bun test` must read the check as
     the same uid the tool runs as.
   - It is not one of the 473cafb fixes, but the task asks that the held-out check never reach the builder. ADR 0012
     says fan-out workers "never [see] the held-out check or its output". ADR 0029 says "A worker cannot fake a pass".
   - Required fix, one of:
     - **(a) Close it.**
       - The tool runs under a uid that cannot read `/check` or the check runner's `/proc` entries. For example: the
         harness starts as root with only `SETUID`/`SETGID`; the check runner runs as uid A with `/check` at `0400`
         and `0500`, owned by A; the tool runs as uid B through a trusted spawn helper.
       - Add a red test: emulated where possible, and a `LIVE:` case. A tool that reads `/check/*` or its parent's
         argv must not pass a held-out check.
     - **(b) Defer it with the owner's explicit acceptance.**
       - Record it in DESIGN.md section 7 and SPEC "Out of scope" with owner m2-08, plus the red test to write.
       - Until it lands, Build progress must not present a held-out pass as independent.

   This is the only finding that blocks.

2. **MINOR: guards that no test pins.** Nine mutations above fail nothing. The code is right today, but nothing stops
   a regression in these four:
   - **Teeth gate:** removing the stop for a check that did not run on the empty workspace (`loop.ts:191`) lets a check
     that hangs or cannot run go on to paid workers.
   - **Tamper check before every attempt:** ADR 0011 requires it; removing it (`attempt.ts:113-117`) fails nothing.
   - **`runAttempt`'s `BuildEnded` → infra** (`attempt.ts:168`): the round 2 response says it is tested, but only the
     loop's path at `loop.ts:265` is. A stale recovery between two tries would bill as `build`.
   - **Exact key set in a claim** (`approvals.ts:244`): without the length check, a claim that adds an extra bound key
     that sorts last is accepted.

   Required fix: one test for each of these four. The others are optional:
   - `--no-install`;
   - the harness's own `tests >= 1` (`parseProof`'s copy of that rule is pinned);
   - artifact size limits;
   - the docker CLI's environment;
   - the `OFFLOAD_PROOF` filter in feedback.

3. **MINOR: sandbox time is never reserved or billed, and no document records that gap.**
   - ADR 0030 says sandbox time counts toward the cap: seconds are reserved at creation (wall × vCPU), and the $4.00 hard
     stop covers model and sandbox time together.
   - Here, `Reservation.kind = "sandbox"` and `Settlement.sandbox_seconds` exist (`store.ts:82, 97`), but nothing
     reserves or writes them.
   - The $0.30 checks reserve is held back (`loop.ts:164`), but nothing is ever charged against it.
   - SPEC "Out of scope" names the egress proxy, not sandbox billing, and DESIGN.md section 7 does not mention it.
   - Required fix: record it with an owner (m2-08, sandbox pricing config), or reserve wall × vCPU in
     `provider.create`'s callers.

4. **MINOR: the `worker_attempts` SQL does not match the DATA_MODEL row this diff edited.**
   - DATA_MODEL.md:203 lists `model`, `wall_seconds`, `replay_pass`, `verifier_verdict`, `repaired`, `diff_lines` and
     `proof jsonb`. `0001_builder.sql:34-54` has none of them.
   - The shard proof is computed (`ShardResult.proof`) and then dropped.
   - Required fix: add the columns as nullable (at least `proof`, `wall_seconds` and `model`), or say in DATA_MODEL or
     DESIGN.md section 4 which columns arrive with m2-07/m2-08.

5. **MINOR (owner actions carried, unchanged since round 1):**
   - the `LOCAL:` red tests and the `redirect: "error"` rule for m5-03 (the ROADMAP row still lacks them);
   - one `LIVE:` Docker run, for network, registry and `swept`;
   - the winner order (artifact bytes, against ADR 0029's smallest diff).

   They are recorded in DESIGN.md sections 6 and 7. They do not block.

6. **NIT: stale wording after round 2's held-out fix.**
   - These still describe the old "used once a worker ran" rule:
     - `loop.ts:3-4` ("used by a build that ran a worker");
     - `loop.ts:215` ("from now on this held-out check counts as used");
     - `store.ts:63`;
     - the test name `HELDOUT: an attempt row exists from the moment a worker starts, so its held-out check counts as used`.
   - DESIGN.md section 1 maps `loop.ts` to a `src/budget.ts` that does not exist.

7. **NIT: the carried test name is not findable.** MIGRATION's `GATE: a wrong brief hash is refused…` is covered by
   `http.test.ts:40`, which loops over all four hashes and the cap. But that test is named for `check_set_hash`. Rename
   it so a grep finds it.

8. **NIT: the `Build` shape is stated three ways.**
   - API.md lists `deployed` but not `started_at`/`ended_at`.
   - The SPEC lists `started_at`/`ended_at` but not `deployed`.
   - `buildView` returns all three (`http.ts:73-75`).
   - Align the docs.

9. **NIT: a build stopped by the cap ends `failed`, not `capped`.** When the cap leaves no room for a fan-out worker, or
   reservations refuse them (`loop.ts:295-298`), and the first worker failed, the build ends `failed`. ADR 0012 step 6
   says reaching the cap ends it `capped`. With the default config this happens only after a worker over-reports its
   spend.

10. **NIT: the start writes before the claim.** `runBuild` changes `queued` to `building` (`loop.ts:144`) before it
    claims the approval. A start with a wrong token therefore ends the user's build `failed`. Only the in-process runner
    can call it today. The durable adapter should claim before, or together with, the compare-and-set.

11. **NIT (p45b): the threshold constants do not decide.** `ON_TRACK` and `PARTIAL` are exported, but the comparison
    hard-codes `8` and `5` (`outcome.ts:116-117`). Derive the integer thresholds from the constants.

p45b: otherwise sound, as in rounds 1 and 2.
- Integer-tenths thresholds.
- Weeks measured once, at their end, from their own days, × 7 / days stored.
- Purged weeks are never guessed.
- Figures carry `source_purged_at` and stable `fig_` ids.

**Required before PASS:** resolve finding 1 by (a) or (b). Add the four tests named in finding 2. Fix or record
findings 3 and 4 with an owner. Findings 6 to 11 are optional. The owner actions in finding 5 stay open.

VERDICT: CHANGES

### Author response (round 3)

Commits `2ab0747..bd8552a`; behaviour changes had a red test committed first.

**Counts after them:**
- p45a slice suite: **134 tests (133 pass, 1 skip `LIVE:`)**, up from 116.
- p45b: **17** (unchanged).
- Full suite: **201 tests across 34 files, 200 pass, 1 skip**.
- Both `verify.sh` PASS; `scripts/verify-all.sh` green.
- On a machine without passwordless `sudo`, the two privileged tests below are skipped as well (3 skips).

Every mutation below was run on a copy in `/tmp`, never in the repo.

1. **MAJOR, fixed by option (a): close it.**
   - **How verification runs now** (Docker, `privilege_split` on by default):
     - **Harness:** starts as root, PID 1, with `--cap-drop ALL` plus only `CHOWN`, `SETGID` and `SETUID`.
     - **Check:** `bun test` runs as the host user that owns `/check`. The check, guard and bunfig are `0400`; the
       harness and spawn client are `0444`.
     - **Spawn broker:** a Unix socket that only the check's user may connect to (`0600`, in a root-owned `0711`
       folder).
     - **Routing:** the guard sends the check's `Bun.spawn`/`Bun.spawnSync` to the broker through `spawn-client.ts`,
       which runs with cwd `/`, so it never reads the artifact's bunfig, tsconfig or `.env`.
     - **Tool:** runs as another user, in `/work`, with the check's group and a clean environment. Temp folders the
       check makes are widened to `0770` so check and tool can still share files. The guard reads `node:fs` through
       `require`: an ES-module import there would stop the patch from reaching the check's named imports, as I found.
     - **Proof:** it carries `split`. A provider that isolates the tool (`isolates_tool`) refuses a pass without
       `split: true`.
     - **Check rules:** checks may not use `child_process`, `Bun.$`, `bun:ffi`, workers, `cluster` or
       `process.dlopen/binding`, which would start the tool as the check's user.
     - The tool can no longer read the held-out check, the check's `/proc` entries or the harness's nonce. That also
       closes DESIGN.md's earlier "same uid, nonce through ptrace" gap.
   - **New tests:**
     - control: without the split, a tool that reads the check passes a held-out check it never solved;
     - a provider that isolates the tool refuses an unsplit pass;
     - **privileged, real users through `sudo`** (skipped without it; GitHub's hosted runners have it): the same cheat
       **fails** under the split, and an honest check that shares a temp folder with the tool **passes**;
     - the exact Docker argv in split mode, and `privilege_split: false` for development;
     - check file modes;
     - refused process APIs;
     - the `LIVE:` Docker test gains the cheat case.
   - **Test changes that are not weakenings:**
     - the emulated guard tests now use `privilege_split: false`, because their emulator cannot be root;
     - three folder-layout assertions gained `spawn-client.ts` and the file modes.
   - **The privileged cheat test fails with each of these removed:**
     - the tool run as the check's user;
     - the guard's routing;
     - the check made world-readable.

     Not requiring the split fails the strict-provider test.
   - (`afba3ea`, red `2ab0747`)
2. **MINOR, fixed (tests).**
   - The four required:
     - the teeth gate stops when a check did not run;
     - the tamper check before the first try;
     - a stale recovery between two tries is billed as infra (`runAttempt`'s `BuildEnded` path);
     - a claim must name exactly the bound keys.
   - The optional ones too: the proof-line filter in feedback, the artifact size limit, the docker CLI's PATH/HOME-only
     environment, and the harness's `--no-install`.
   - Each of the eight fails one test with its guard removed. (`1482fdb`)
3. **MINOR, recorded.** Sandbox-time billing (ADR 0030) is in SPEC "Out of scope" and DESIGN.md section 7, owner
   m2-08 with the sandbox price config. `worker_attempts.wall_seconds` is now written for it. (`bd8552a`)
4. **MINOR, fixed.**
   - `worker_attempts` gains `proof jsonb` and `wall_seconds`, both written.
   - `model`, `replay_pass`, `verifier_verdict`, `repaired` and `diff_lines` are added as nullable columns for
     m2-07/m2-08.
   - The per-shard proof is kept: status, exit, tests, completed, swept, split, never the nonce.
   - New tests: a Postgres column check against DATA_MODEL and a round trip, plus the loop recording proofs and wall
     time. (`464f101`, red `d128e08`)
5. **Owner actions, unchanged:** the `LIVE:` Docker run (it now also covers the cheat), the `LOCAL:` tests for m5-03,
   and the winner order.
6. **NIT, fixed.** The stale "used once a worker ran" wording is gone from `loop.ts`, `store.ts` and the test name.
   DESIGN.md section 1 no longer names `src/budget.ts`. (`3ad5f65`)
7. **NIT, fixed.** `http.test.ts` now carries the name `GATE: a wrong brief hash is refused as forbidden (403
   hash_mismatch) before any check is written or any worker runs…`. (`3ad5f65`)
8. **NIT, fixed.** API.md and the SPEC both list `deployed`, `started_at` and `ended_at`, as `buildView` returns.
   (`3ad5f65`)
9. **NIT, fixed.** When no fan-out worker fits the cap, the build ends `capped` with the first worker's reason. New
   `BUDGET:` test. (`77f5a27`, red `fb91670`)
10. **NIT, recorded, not changed.** Claiming before the compare-and-set would change what a wrong-token start does to a
    queued build (today `failed`, per the `GATE:` test). Only the in-process runner starts builds. DESIGN.md section 7
    asks the W1-C durable adapter to claim before, or together with, the compare-and-set. (`bd8552a`)
11. **NIT, fixed.** The p45b thresholds are integer tenths derived from `ON_TRACK` and `PARTIAL`. (`8f5a285`)

## Round 4

Independent review (Opus 5.5; wrote none of the code and none of rounds 1 to 3), 2026-11-22, branch `port/build-loop` at
`345e84d`, diff `8f6ff2d..345e84d` (focus: `3321961..345e84d`, the round 3 fixes).

**Read:**
- AGENTS.md and CLAUDE.md;
- both SPECs, DESIGN.md, and rounds 1 to 3 with their author responses;
- ADR 0011 and the ADRs the SPEC cites;
- the API.md builds rows;
- SECURITY_PRIVACY sections 8 and 13;
- every source file changed since round 3: `harness.ts` (all of it), `sandbox/docker.ts`, `sandbox/provider.ts`,
  `shards.ts`, `loop.ts`, `attempt.ts`, `checks.ts`, `heldout.ts`, `store.ts`, `store-pg.ts`, the SQL and p45b's
  `outcome.ts`;
- `git diff 3321961..HEAD` on both test folders, every removed line included.

### Runs (this reviewer, DATABASE_URL set, passwordless `sudo` available, no Docker)

| Command | Result |
|---|---|
| `bash scripts/verify-all.sh` | `verify-all: green` (exit 0). Full suite **201 tests across 34 files: 200 pass, 1 skip (`LIVE:` Docker), 0 fail**. p45a and p45b both PASS. Slices (10 specs), doc links (70 files), copy, secrets and workflows are ok, and the license boundary holds. Swift is skipped (needs macOS) |
| `bash slices/p45a-build-loop/verify.sh` | `p45a-build-loop: PASS`. Slice suite **134 tests across 10 files: 133 pass, 1 skip, 0 fail** (min 75). All 24 tags pass: GATE 12, CHECKS 5, HELDOUT 11, TEETH 5, DEFAULT1 1, SHARDS 22, FANOUT 9, STALL 2, LOCK 14, SHIP 4, BUDGET 6, CAP 3, TAMPER 2, PROOF 3, VERDICT 1, SANDBOX 15, INFRA 3, DEPLOY 1, READY 4, TDD 3, STEPS 1, ERROR 1, API 3, RLS 2. Full suite 201. Scope checked (47 files) |
| `bash slices/p45b-measured-saving/verify.sh` | `p45b-measured-saving: PASS`. Slice suite **17 tests across 1 file: 17 pass** (min 12). SHIP 3, MEASURE 6, FLAG 2, MONTH 1, OUTCOME 2, FIGURE 3. Full suite 201. Scope checked (38 files) |
| Privileged tests | `sudo -n true` works here, so both `(privileged)` split tests ran and passed. The only skip is `LIVE:` |
| Scope | Every changed file matches `paths_in_scope`. Nothing changed under `packages/{db,contracts,policy,testkit,routine-sdk,connectors-sdk}`, `services/{api,runtime,broker,brain}`, `apps`, `ee`, `.github` or `docs/adr`. `bun.lock` and `package.json` are unchanged. NOTICE lists superpowers (MIT text), craft-anything, apple/container, container-use, exo and CompanyOS (ideas only) |
| Hygiene | After all runs: no `p45a%` schema or role left in Postgres, no `offload-sbx-*` folder left in `/tmp`, and `git status` was clean before this file was written |

### Mutation checks (tests really fail without the code)

How I ran them:
- `/tmp/r4-mut/run.sh` (outside the repo) applied each change in the tree with `perl -0pi` and checked that the file
  changed.
- It ran both slice folders (151 tests), then restored the file with `git checkout --`.
- No stash was used. `git status` was clean after each batch.

**The round 3 user split**

| Mutation | Failing tests |
|---|---|
| broker runs the tool as the check's user (`harness.ts:150`) | 1 (privileged cheat) |
| guard's spawn routing off (`harness.ts:45`) | 1 (privileged cheat) |
| verification check files `0444` instead of `0400` (`harness.ts:293`) | 2 |
| split proof not required (`shards.ts:72`) | 2 (`SHARDS:` strict provider, `PROOF:`) |
| harness never splits (`harness.ts:113`) | 2 (both privileged) |
| temp folders not widened (`harness.ts:49`) | 1 (privileged honest check) |
| process-API refusal off (`checks.ts:59`) | 1 (`CHECKS:`) |
| development provider forced to split (`docker.ts:62`) | 4 |

**473cafb and the earlier security fixes (all still fail)**

| Mutation | Failing tests |
|---|---|
| `bun test` cwd = `/work` (`harness.ts:182`) | 8 (`SHARDS:` planted bunfig, node_modules/tsconfig/imports, `.env`, …) |
| no `--config` / no `--no-env-file` | 2 / 2 |
| guard `onResolve` off / `onLoad` off | 1 / 2 |
| held-out check left out of the teeth gate (`loop.ts:183`) | 4 (`TEETH:`, `HELDOUT:`) |
| an attempt's error rejects instead of resolving (orphans, `loop.ts:261`) | 1 (`LOCK:`) |
| stale recovery off, memory / Postgres | 4 / 3 (`LOCK:`, `HELDOUT:`) |
| `--network none` → `bridge` | 1 |
| `/check` mounted read-write | 3 |
| no `--cap-drop ALL` / no `--read-only` / an extra `SYS_ADMIN` | 1 each |
| an exec error counted as a pass (`shards.ts:53`) | 5 |
| proof nonce not compared (`harness.ts:284`) | 1 (`PROOF:`) |
| approval TTL off / single use off / bound hashes not compared | 2 / 3 / 3 (`GATE:`) |
| OK's hash gate off (`loop.ts:79`) | 1 (`GATE:` wrong brief hash) |
| reservation ceiling off (memory) / `FOR UPDATE` off (Postgres) | 1 / 2 (`CAP:`) |
| held-out output added to the fan-out feedback (`loop.ts:252`) | 1 (`FANOUT:`) |
| `..` allowed in a sandbox path (`provider.ts:336`) | 1 |
| `capped` when no fan-out fits removed / `proof` not written / `wall_seconds` not written | 1 / 1 / 1 |

**Mutations that fail nothing (finding 3)**

| Mutation | Failing tests |
|---|---|
| broker accepts a tool cwd outside `/work` (`harness.ts:144`) | **0** |
| tool inherits the harness's environment (`harness.ts:150`) | **0** |
| broker socket `0666` (`harness.ts:167`) | **0** |
| broker's tools not killed after the check (`harness.ts:185`) | **0** |
| no `kill(-1)` sweep (`harness.ts:190`, known: `LIVE:` only) | **0** |
| report folder `0755` (`harness.ts:118`) | **0** |

### Red commits and test history since round 3

**Red commits.** Each red commit, exported to `/tmp` (`git archive`) and run with its own code, fails as claimed:
- `2ab0747`: 11 fail;
- `d128e08`: 2 fail;
- `fb91670`: 1 fail.

`1482fdb` adds tests only, for code that already existed.

**Removed test lines since `3321961`:**
- Two folder-layout `toEqual`s gained `spawn-client.ts` and the file modes. Stricter.
- The argv pin swaps `--user 65534:65534` for the split argv. It still pins every flag exactly, and the non-split argv
  has its own new test.
- The guard emulator is refactored. It gains a sudo mode and a `0o1777` tmpfs.
- The old guard tests now run with `privilege_split: false`. That is exactly the pre-split behaviour they were written
  for, and the split has its own tests.
- One test was renamed for NIT 6 and one for NIT 7.

**No assertion is weakened.**

**Other checks:**
- No `.skip`, `.todo`, `.only` or `it(`. The skips are `describe.skipIf(!dockerUp)` (`LIVE:`) and
  `test.skipIf(!sudoOk)` (2, ran here).
- MIGRATION 5.6's carry list is unchanged since round 3. Every name is present, `LOCAL:` is handed to m5-03 and the
  `GATE: a wrong brief hash…` name is now findable (`http.test.ts`).
- SECURITY section 13 builder rows each have a test. "Outbound connection fails; no registry reachable" is still only
  the never-run `LIVE:` test.

### My own attacks on the user split (scratch tests in `/tmp/r4-scratch`, repo emulator under `sudo`)

**The cheat tool fails.** The held-out check expects `zq-7781-unguessable`, and the tool reads `/check` and every
`/proc/*/cmdline` to find it. It fails (`split: true`, the tool's output is `I do not know 65534`) when the check starts
it through any of:
- `Bun.spawnSync`;
- `import { spawnSync } from "bun"`;
- `import * as B from "bun"`;
- an async `import { spawn } from "bun"`.

I expected the guard's own ESM `import { plugin } from "bun"` to freeze the named import before the patch. It does not:
named imports of `"bun"` are live.

**The tool finds nothing else:**
- It has `groups=<check gid>` only: supplementary groups are dropped.
- Nothing under the shared `/tmp` contains the secret.
- No other user's `/proc/<pid>/fd` is readable.

**The verification path fails closed.** A harness that cannot split produces no proof. The teeth gate then ends the
build "could not run" before any paid worker (`loop.ts:191`).

### Round 3 findings, status

| Finding | Status |
|---|---|
| 1 MAJOR (tool reads the held-out check) | **Fixed** for verification, by option (a). Mutations fail tests, and my own attacks fail. Real Docker is still unrun (finding 4). See finding 1 below for a side effect of the fix |
| 2 (unpinned guards) | Fixed: the four required and the four optional each fail a test now |
| 3 (sandbox time) | Recorded with owner m2-08 (SPEC Out of scope, DESIGN section 7) |
| 4 (`worker_attempts` columns) | Fixed: the columns match DATA_MODEL, and `proof` and `wall_seconds` are written and pinned |
| 5 (owner actions) | Carried (finding 4) |
| 6, 7, 8, 9, 11 | Fixed |
| 10 | Recorded with owner W1-C |

### Findings

1. **MAJOR: the user split runs *every* Docker exec as container root with `CHOWN`, `SETUID` and `SETGID`, not only
   the trusted harness. Untrusted worker commands get root on a read-write host bind mount. This reverses DESIGN.md
   hole 12, which the docs still list as fixed.**
   - Evidence:
     - `docker.ts:187` and `docker.ts:191`: with `privilege_split` on (the default, `docker.ts:62`), `runArgv` emits
       `--user 0:0 --cap-add CHOWN --cap-add SETGID --cap-add SETUID` and the split env for every `exec`, whatever
       the `argv` or role.
     - `attempt.ts:39` and `attempt.ts:131`: `WorkerTurn` hands this `provider` and the worker `sandbox` to m2-07's
       Agent SDK worker, which "writes into /work through the provider". Its tool calls will be `provider.exec(...)`
       of model-written commands.
     - `/work` is a host bind mount (`docker.ts:193`) without `nosuid`. Without user-namespace remapping, container
       uid 0 is host uid 0 on it.
     - Scratch run (repo emulator under `sudo`; these operations need no capability, so `--cap-drop ALL` does not
       stop them): a `role: "worker"` exec of `bun -e` ran as `uid=0`. It left a copy of `bun` in the **host**
       folder `…/offload-sbx-*/work/rootsh` with **uid 0, mode 4755** (a setuid-root binary on the builder host). It
       also left a `0700` root-owned folder.
     - In the same run, `destroy()` then threw `EACCES` and left the host sandbox folder behind. `docker.ts:236`
       `rmSync` throws in `finally`, so `boxes.delete` never runs either.
     - Without the split (and before round 3) the same exec runs as `65534:65534` with no added capability, and could
       do neither.
   - The docs still say the opposite:
     - DESIGN.md:53 (hole 12: "v2 adds `--user 65534:65534`");
     - DESIGN.md:77 ("every `exec` is `docker run … --user 65534:65534`");
     - `docker.ts:3` ("Hardened beyond it: a non-root user").

     m2-07 will build on the port contract and on these lines.
   - No test pins a non-harness exec as unprivileged. The argv tests use the harness `argv` (split) or
     `privilege_split: false`.
   - Why MAJOR, although today only the harness is exec'd:
     - The slice ships the `SandboxProvider` and `WorkerTurn` contract that m2-07 fills in.
     - The default makes the first real worker command root on the host mount.
     - The security doc that m2-07 will read says that cannot happen.
     - SECURITY section 8 ("never run untrusted build code as a user who has secrets…") and the self-host
       host-takeover row assume the worker is unprivileged.
   - Required fix:
     - Grant root and the three capabilities only to the trusted harness exec: an explicit `ExecOptions` flag (for
       example `harness: true`) set only by `shards.ts` and the advisory run in `attempt.ts`. Every other exec on a
       split provider runs `--user 65534:65534` with no `--cap-add` and no `OFFLOAD_*_UID` env.
     - Add a red `SANDBOX:` test: a split provider's non-harness exec (worker role) has `--user 65534:65534` and no
       `--cap-add`.
     - Update DESIGN.md holes 12 and section 3 and the `docker.ts` header to say exactly who runs as root.
     - Make `destroy()` drop the `boxes` entry even when `rmSync` fails.

2. **MINOR: `split: true` is asserted, not probed.**
   - `harness.ts:113` sets `SPLIT` from "I am uid 0 and `OFFLOAD_CHECK_UID` is set". The proof then says
     `split: true` (`harness.ts:209`), and `shards.ts:72` trusts it.
   - What actually protects the check is the bind mount enforcing the host owner and `0400` inside the container.
     Some setups break that:
     - rootless Docker or `userns-remap`: they fail closed (the check user cannot read its own check), which is fine.
     - a file-sharing layer that does not enforce owner modes (some desktop or FUSE mounts): the harness would still
       report `split: true` while the tool can read the held-out check.
   - Required fix: before running the check, the harness spawns a probe as `TOOL_UID` that tries to open
     `/check/<FILE>`. It reports `split: true` only when that fails with `EACCES`, and add a test. Or record the
     supported Docker setups (Linux engine, no desktop file sharing) in DESIGN.md section 7.

3. **MINOR: the root-side broker rules are unpinned.** Six mutations above fail nothing:
   - the tool cwd rule;
   - the tool's clean environment;
   - the socket mode;
   - killing the broker's tools;
   - the `kill(-1)` sweep (known, `LIVE:`);
   - the report folder mode.

   None of them leaks the check today: the tool's uid alone protects it. But they are the broker's own guards on a
   root process. Required fix: one test each for the cwd refusal, the clean environment (no `OFFLOAD_*` reaches the
   tool) and the socket mode. The other three are optional.

4. **MINOR (owner actions, carried, now weightier):**
   - The `LIVE:` Docker run has never run. It is now the only proof that the default production path (root PID 1 with
     three capabilities under `no-new-privileges`, `chown` on the bind mount, the Unix-socket broker) works on a real
     engine, besides network and registry denial and `swept`. Run it once on a Linux Docker host before m2-07/m2-08
     rely on it.
   - Still open, unchanged:
     - the `LOCAL:` tests and the `redirect: "error"` rule for m5-03;
     - the winner order (bytes against ADR 0029's smallest diff);
     - sandbox-time billing (m2-08);
     - start before claim (W1-C).

5. **NIT: the split changes what a check can do, and the check writer is not told.**
   - Under the split, the guard drops the check's `env` for the tool and refuses `stdin` that is not a string or
     bytes (`harness.ts:57-65`).
   - A check that passes `env` to the tool therefore passes with `privilege_split: false` and fails in production.
   - The tool also shares the check's temp folders through the group (`0770`), so a daemonised tool can read anything
     a later test writes there.
   - Add to `HELDOUT_WRITER_SYSTEM` (`heldout.ts:16`): no environment variables for the tool, and never write expected
     values into the temp folder. Or refuse `env:` in `disallowedProcessApi`.

p45b: sound. The round 3 NIT 11 fix derives the integer tenths from `ON_TRACK` and `PARTIAL`. Rounding is exact for
0.8 and 0.5, and the `OUTCOME:` tests (80, 50 and 49%) pin it.

**Required before PASS:**
- Fix finding 1: root only for the harness exec, a red test, and the docs.
- Fix finding 2 or record it, and add the finding 3 tests.
- Finding 4 stays with its owners. Finding 5 is optional.

VERDICT: CHANGES

### Author response (round 4)

Commits `e661e49..9948036`; behaviour changes had a red test committed first.

**Counts after them:**
- p45a slice suite: **140 tests (139 pass, 1 skip `LIVE:`)**, up from 134. Six of them are privileged and are skipped
  without passwordless `sudo` (they ran here).
- p45b: **17** (unchanged).
- Full suite: **207 tests across 34 files, 206 pass, 1 skip**.
- Both `verify.sh` PASS; `scripts/verify-all.sh` green.

Every mutation below was run on a copy in `/tmp`, never in the repo.

1. **MAJOR, fixed.**
   - `ExecOptions.harness` is new. Only `shards.ts` and the advisory run in `attempt.ts` set it.
   - On a split provider only that exec gets `--user 0:0 --cap-add CHOWN --cap-add SETGID --cap-add SETUID` and the
     `OFFLOAD_*_UID` env. Every other exec (a worker's command above all, any role) runs as `--user 65534:65534` with no
     `--cap-add`, as before round 3.
   - `destroy()` forgets the sandbox even when its folder cannot be removed. The folder is left for the reaper; nothing
     is thrown at the ending build.
   - DESIGN.md hole 12 and section 3, and the `docker.ts` header, now say exactly who runs as root.
   - New tests:
     - `SANDBOX:` a split provider's non-harness exec (worker and verification roles) runs as `65534:65534` with no
       `--cap-add` and no uid env, and its harness exec gets exactly the three capabilities;
     - shard and advisory execs carry `harness: true`;
     - `destroy` copes with a folder it cannot remove.
   - Mutations:
     - root for every exec on a split provider: 1 fail;
     - shards not flagged as harness: 6 fail;
     - `destroy` throwing again: 1 fail.
   - (`5d682f1`, red `e661e49`)
2. **MINOR, fixed.**
   - Before the check runs, the harness spawns a probe as `TOOL_UID` (cwd `/`, `--no-env-file`) that opens
     `/check/<FILE>`. The proof says `split: true` only when that got `EACCES`.
   - New privileged test: with a mount that ignores modes (the check written `0444`), an honest check that passes still
     reports `split: false`, and the isolating provider refuses the pass.
   - Mutation: probe ignored, 2 fail.
   - (`0f206a7`, red `433e4de`)
3. **MINOR, fixed (tests).** Privileged tests, each pinning a broker rule:
   - a tool cwd outside `/work` is refused (exit 126, "refused");
   - the tool's environment is `HOME`, `PATH` and `TMPDIR` only, apart from the `NODE` and `npm_*` that `bun run` adds
     to its own process;
   - the tool's user cannot connect to the broker socket.

   Each fails with its rule removed: cwd rule off, the harness env inherited, the socket `0666` (1 fail each). The
   optional three (killing the broker's tools, the `kill(-1)` sweep, the report folder mode) are not pinned: the first
   two need a PID-1 container (`LIVE:`), and the third is not a leak path. (`433e4de`)
4. **Owner actions, carried.** DESIGN.md section 7 now says the `LIVE:` run on a Linux Docker engine is the only proof of
   the production split path (recorded in `9948036`), as well as network and registry denial, `swept` and the cheat case, and must run before
   m2-07/m2-08 rely on it. Unchanged and recorded: the `LOCAL:` tests for m5-03, the winner order, sandbox-time billing
   (m2-08), start before claim (W1-C).
5. **NIT, fixed.** `HELDOUT_WRITER_SYSTEM` now tells the writer:
   - the tool gets no environment variables from the check (give input as arguments, a stdin string or files);
   - the tool can read the temp folder, so the expected values are never written there.

   New assertion in the held-out writer test. (`ab11acf`, red `e0813d7`)

## Round 5

Independent review (Opus 5.5; wrote none of the code and none of rounds 1 to 4), 2026-11-22, branch `port/build-loop` at
`6b3b10e`, diff `8f6ff2d..6b3b10e` (focus: `f7dcf98..6b3b10e`, the round 4 fixes).

**Read:**
- AGENTS.md (review gate) and CLAUDE.md;
- both SPECs, DESIGN.md, and rounds 1 to 4 with their author responses;
- the DATA_MODEL builds rows (section 6) and `budget_entries` (section 8);
- the API.md builds rows;
- SECURITY_PRIVACY section 13;
- MIGRATION 5.6 (carry list);
- every source file of `services/builder/src` (all of `harness.ts`, `sandbox/docker.ts`, `sandbox/provider.ts`,
  `shards.ts`, `attempt.ts`, `loop.ts`, `approvals.ts`, `checks.ts`, `heldout.ts`, `store-pg.ts`, `http.ts`), the SQL
  and p45b's `outcome.ts`;
- `git diff 345e84d..HEAD` on both test folders, and every removed `expect` line since `8f6ff2d`.

### Runs (this reviewer, DATABASE_URL set, passwordless `sudo` available, no Docker)

| Command | Result |
|---|---|
| `bash scripts/verify-all.sh` | `verify-all: green` (exit 0). Full suite **207 tests across 34 files: 206 pass, 1 skip (`LIVE:` Docker), 0 fail**, 839 `expect()` calls. p45a PASS (scope 47 files), p45b PASS (scope 38 files). Slices (10 specs), doc links (70 files), copy, secrets and workflows are ok, and the license boundary holds. Swift is skipped (needs macOS) |
| `bash slices/p45a-build-loop/verify.sh` | `p45a-build-loop: PASS` (exit 0). Slice suite **140 tests across 10 files: 139 pass, 1 skip, 0 fail** (min 75). All 24 tags pass: GATE 12, CHECKS 5, HELDOUT 11, TEETH 5, DEFAULT1 1, SHARDS 26, FANOUT 9, STALL 2, LOCK 14, SHIP 4, BUDGET 6, CAP 3, TAMPER 2, PROOF 3, VERDICT 1, SANDBOX 17, INFRA 3, DEPLOY 1, READY 4, TDD 3, STEPS 1, ERROR 1, API 3, RLS 2. Full suite 207. Scope checked (47 files) |
| `bash slices/p45b-measured-saving/verify.sh` | `p45b-measured-saving: PASS` (exit 0). Slice suite **17 tests across 1 file: 17 pass** (min 12). SHIP 3, MEASURE 6, FLAG 2, MONTH 1, OUTCOME 2, FIGURE 3. Full suite 207. Scope checked (38 files) |
| Privileged tests | `sudo -n true` works, so all six `(privileged)` tests ran and passed. The only skip is `LIVE:` |
| Scope | Every changed file matches `paths_in_scope`. Nothing changed under `packages/{db,contracts,policy,testkit,routine-sdk,connectors-sdk}`, `services/{api,runtime,broker,brain}`, `apps`, `ee`, `.github` or `docs/adr`. `bun.lock` and `package.json` are unchanged. NOTICE lists superpowers (with the MIT text), craft-anything, apple/container, container-use, exo and CompanyOS (ideas only) |
| Hygiene | No `console.*` or logging in `src` (the only stdout write is the harness's proof line). After all runs: no `p45a%` schema or role in Postgres, no `offload-sbx-*` or `offload-p45a-*` folder in `/tmp`, and `git status` was clean before this file was written |

### Mutation checks (tests really fail without the code)

How I ran them:
- `/tmp/r5-mut/mut.sh` (outside the repo) applied each change in the tree with `perl -0pi`, checked that the file
  changed, and ran both slice folders.
- It then restored the file with `git checkout --`. No stash was used, and `git status` was clean after each batch.

**The round 4 fixes**

| Mutation | Failing tests |
|---|---|
| root for every exec on a split provider (`docker.ts:173`) | 1 (`SANDBOX:` only the harness runs as root) |
| shards not flagged `harness: true` (`shards.ts:241`) | 6 (privileged) |
| advisory run not flagged `harness: true` (`attempt.ts:145`) | 1 (`SANDBOX:` worker sandboxes) |
| probe result ignored, `proven = true` (`harness.ts:183`) | 1 (privileged, mount that ignores modes) |
| probe accepts any failure, `status !== 0` (`harness.ts:183`) | **0** (NIT 6) |
| `destroy` rethrows `rmSync` (`docker.ts:245`) | 1 |

**473cafb and the earlier security fixes (all still fail)**

| Mutation | Failing tests |
|---|---|
| `bun test` cwd = `/work` (`harness.ts:191`) | 12 (`SHARDS:` planted bunfig, node_modules, tsconfig, imports, `.env`, …) |
| guard `onLoad` off / Bun.spawn routing off | 2 / 4 |
| `--network none` → `bridge` / `/check` read-write / no `--cap-drop ALL` / no `--read-only` | 1 / 2 / 2 / 1 |
| an exec error or missing proof counts (`proof.ok` dropped, `shards.ts:248`) | 2 (`PROOF:`) |
| split proof not required (`shards.ts:247`) | 3 |
| approval TTL off / single use off / bound hashes not compared | 2 / 3 / 3 (`GATE:`) |
| OK's hash gate off (`loop.ts:79`) | 1 (`GATE:` wrong brief hash, 403) |
| reservation ceiling off (memory) / `FOR UPDATE` off (Postgres) / Postgres ceiling ×100 | 1 / 2 / 2 (`CAP:`) |
| held-out check left out of the teeth gate (`loop.ts:183`) / teeth write check off | 4 / 1 |
| held-out output appended to the fan-out feedback (`loop.ts:253`) | 1 (`FANOUT:`) |
| `HeldOutUsed` off, memory / Postgres | 2 / 1 |
| `..` allowed in a sandbox path (`provider.ts`) | 1 |
| heartbeat before a try off (`attempt.ts:130`) | 2 (`LOCK:`) |
| deploy once off (`http.ts:128`) | 1 (`SHIP:`) |
| fan-out not awaited (`loop.ts:301`) | 10 |
| orphans: `runAttempt` and `attemptOnce` both rethrow | 4 (`FANOUT:`, `ERROR:`, `READY:`). Either layer alone: 0, because the other one catches. That is by design |
| `--no-env-file` removed from the harness's `bun test` (`harness.ts:190`) | **0** (NIT 6; cwd `/check` already keeps `/work/.env` out) |

### Test history

- Since round 4 (`345e84d..HEAD`) the only change to an existing test adds `harness: true` to the argv pin
  (`docker.test.ts:38`). That test pins the root argv, which now needs the flag. `5d682f1`'s one removed `expect` line
  is the same assertion with `x` renamed `_x`.
- Every other removed `expect` line since `8f6ff2d` was reviewed in rounds 1 to 4: `724dbd3`'s loosening was restored
  in `4733412`, and the rest are refactors or became stricter.
- **No assertion is weakened.**
- No `.skip`, `.todo`, `.only` or `it(`. The skips are `describe.skipIf(!dockerUp)` (`LIVE:`) and six
  `test.skipIf(!sudoOk)` (they ran here).
- The red commits `e661e49`, `433e4de` and `e0813d7` precede their code commits.
- MIGRATION 5.6's carry list is all present in v2 words. `LOCAL:` is handed to m5-03, and `RUNTIME:` was dropped as
  MIGRATION plans.
- Every builder row of SECURITY section 13 has a test, but "no registry reachable" is only the never-run `LIVE:` test.

### My own checks (scratch files in `/tmp/r5-scratch`; nothing in the repo changed)

1. **The privileged tests under the container's real capability set.**
   - `guard.test.ts:79` runs the harness through `sudo env -i …`: root with **every** capability.
   - Its comment (`guard.test.ts:34`) says it emulates the container, "where it is PID 1 with SETUID, SETGID and CHOWN
     only".
   - I ran a copy of `guard.test.ts` whose only change wraps that command in `setpriv
     --bounding-set=-all,+chown,+setuid,+setgid --inh-caps=-all --no-new-privs`. The harness's `CapEff` is then
     `0xc1`, exactly `--cap-drop ALL --cap-add CHOWN --cap-add SETGID --cap-add SETUID`.
   - Result: **all six privileged tests fail.** The harness dies before it prints a proof: `EPERM: operation not
     permitted, chmod '…/offload-run-…'` at `harness.ts:119`.
   - With the two `chown`/`chmod` pairs swapped in a copy of `src` (finding 1), all six pass.
2. **Worker-made folders.** I emulated a worker command with `setpriv --reuid=65534 --regid=65534 --clear-groups sh -c
   "umask 022; mkdir tests && echo x > tests/a.test.ts"` inside `work`. `destroy()` then left the host sandbox folder
   behind (`existsSync(root)` true), forgot it, and `list(tag)` no longer returned it (finding 2).
3. **The check linter.** `parseCheckReply` accepts checks that start the tool outside the broker:
   - `const { $ } = Bun`;
   - `` Bun["$"]`…` ``;
   - `process.getBuiltinModule("node:child_process")`, which returns `child_process` on Bun 1.4.4.

   `Bun.$` itself is refused (finding 3).

### Round 4 findings, status

| Finding | Status |
|---|---|
| 1 MAJOR (root for every exec) | **Fixed.** `harness: true` alone gets root (`docker.ts:173`), with a test and docs. Mutations fail tests. See NIT 5 for hardening |
| 2 (split asserted, not probed) | **Fixed** (`harness.ts:180-184`), with a test. The 3-vs-4 exit code is unpinned (NIT 6) |
| 3 (broker rules unpinned) | **Fixed**: cwd, clean env and socket each fail a test |
| 4 (owner actions) | Carried. Finding 1 below shows why the `LIVE:` run matters: the emulation differs from the container |
| 5 (writer not told about the split) | Fixed (`heldout.ts:274`) |

### Findings

1. **MAJOR: under the container's real capabilities the user-split harness crashes before it prints a proof. The
   default Docker provider can therefore never pass a check, and every build ends at the teeth gate. The privileged
   tests miss it because `sudo` grants every capability.**
   - Evidence:
     - `harness.ts:119`: `chownSync(run, CHECK_UID, CHECK_GID); chmodSync(run, 0o711);`.
     - `harness.ts:167-168`: `chownSync(socketPath, …); chmodSync(socketPath, 0o600);`.
     - After the `chown`, root no longer owns the folder, and `chmod` on a file you do not own needs `CAP_FOWNER`.
       `docker.ts:193` grants only `CHOWN`, `SETGID` and `SETUID` after `--cap-drop ALL`, so the call is `EPERM` on any
       Linux kernel.
     - `privilege_split` defaults to true (`docker.ts:66`), so this is the production path.
     - My check 1: under exactly `CapEff 0xc1` every privileged test fails, with that `EPERM` in the harness output.
       Swapping the two pairs makes all six pass.
   - Effect:
     - No proof line, so the shard is `ran: false` and `passed: false` (`shards.ts:243-248`).
     - The teeth gate ends every build "The teeth gate could not run the checks." before any worker (`loop.ts:191`).
     - This fails closed: nothing false passes. But the slice's default verification path cannot produce a single
       verdict.
   - The tests' cover:
     - `guard.test.ts:79` runs the harness as full root (`sudo env -i`), while its comment (`guard.test.ts:34`) says
       it emulates the container's three capabilities.
     - Rounds 3 and 4 and the author's mutation runs all relied on that emulation. Nothing pins the capability set the
       harness really gets.
   - Required fix:
     - In the harness, `chmod` before `chown`, in both places.
     - Make the privileged emulator run the harness with the container's capability set: wrap the command in `setpriv
       --bounding-set=-all,+chown,+setuid,+setgid --inh-caps=-all --no-new-privs` (util-linux; present on GitHub's
       Ubuntu runners). Skip the test when `setpriv` is missing, and never fall back to full root.
     - Red first: the emulator change alone turns the six privileged tests red on the current harness.
     - Fix the comment at `guard.test.ts:34`.

2. **MAJOR: `destroy()` cannot remove any folder a sandbox user made, and since round 4 it then forgets the sandbox
   silently. In normal use every worker sandbox's host folder (the artifact, and any fixture copies the worker made)
   stays on the builder host forever, where no reaper can find it.**
   - Evidence:
     - A worker's commands run as `65534:65534` (`docker.ts:193`) with Docker's default umask `022`, so every folder
       they make in `/work` is `0755`, owned by `65534`, on the host bind mount.
     - The builder (another host uid) cannot unlink entries inside such a folder, so `rmSync(b.root, …)` fails. The
       error is swallowed (`docker.ts:245-249`), and `boxes.delete` runs first (`docker.ts:244`).
     - `list(tag)` (`docker.ts:254-263`) only knows in-memory boxes and live containers, so the "left for the reaper"
       comments (`docker.ts:242`, `docker.ts:248`) and the test name "the reaper takes it from there"
       (`docker.test.ts:102`) promise something nothing can do: nothing records the folder.
     - This is the normal path, not an attack:
       - `TDD_INSTRUCTIONS` (`attempt.ts:20`) tells every worker to write its tests in `tests/`;
       - m2-07's Agent SDK worker runs inside the sandbox;
       - in verification shards, the built tool also runs as `65534` with cwd `/work`.
     - My check 2 reproduced it with a uid-65534 `mkdir tests`.
   - Why MAJOR:
     - The SPEC's `SANDBOX:` row promises "temps removed", and DESIGN section 3 says sandboxes are destroyed.
     - The leftover folders hold worker code and whatever the worker copied from `/check/fixtures` (tokenised fixture
       content, `R-content`) outside any retention, purge or forget.
     - The disk use grows with every attempt on a self-hosted builder.
   - Required fix:
     - Before `rmSync`, empty `/work` from inside a sandbox as the user that made the files. For example, one cleanup
       `docker run --rm --user 65534:65534 --network none --cap-drop ALL … --entrypoint find <image> /work -mindepth 1
       -delete` over the same mount: `65534` can unlink anything in folders it owns, and the builder removes the rest.
       Alternatively, run sandbox execs with umask `000`.
     - If removal still fails, keep a record the reaper can use: a persisted list of leftover folders, returned by
       `list(tag)`. Do not just forget it.
     - Red test: under `sudo`, a uid-65534 folder with a file in `work`; after `destroy()` the sandbox root is gone.
     - Rename the round 4 test so it no longer promises a reaper.

3. **MINOR: the check linter is the only guard against a check that starts the tool outside the broker, and it can
   be bypassed. Under the split, such a tool runs as the check's user, can read the held-out check, and its pass still
   counts.**
   - `checks.ts:218-232` refuses `Bun.$`, `import { $ } from "bun"`, `child_process`, workers and `dlopen`. My check 3
     shows that `const { $ } = Bun`, `` Bun["$"] `` and `process.getBuiltinModule("node:child_process")` all pass
     `parseCheckReply`.
   - The guard (`harness.ts:45-69`) routes only `Bun.spawn` and `Bun.spawnSync`. The harness still reports `split:
     true` (the probe passed), so `shards.ts:247` accepts the result.
   - The check writer is Offload's own model, not the attacker, so this needs a careless check. That is why it is
     MINOR. But it fails open.
   - Required fix:
     - Under the split, the guard makes every other process API fail at run time: `Bun.$`, `process.getBuiltinModule`,
       and the functions of `require("node:child_process")` (`spawn`, `spawnSync`, `exec*`, `execFile*`, `fork`).
     - Add `getBuiltinModule`, `Bun[` and destructuring from `Bun` to the linter.
     - Add a privileged test where a check that uses `const { $ } = Bun` cannot pass with a tool that reads the check.

4. **MINOR (owner actions, carried):**
   - The `LIVE:` Docker run has still never run. Finding 1 shows what it would have caught: the emulation is not the
     container. Run it on a Linux engine after finding 1 is fixed, before m2-07/m2-08 rely on the split.
   - Still open, unchanged:
     - `LOCAL:` tests and `redirect: "error"` for m5-03;
     - the winner order (bytes against ADR 0029's smallest diff);
     - sandbox-time billing (m2-08);
     - start before claim (W1-C);
     - the image pin (S4).

5. **NIT: root is granted on a caller's word.** `runArgv` gives root and three capabilities to any `exec` with
   `harness: true` (`docker.ts:173`), whatever its argv. `WorkerTurn` hands the whole provider to m2-07's worker
   (`attempt.ts:25-27`). Make the provider refuse `harness: true` unless `argv` is exactly `HARNESS_ARGV` and `cwd` is
   `/check`, or give the worker a narrowed handle without the flag. Then a model-written command can never get root by
   a slip in m2-07.

6. **NIT: two defensive rules are unpinned.**
   - The probe's "only `EACCES` (exit 3) proves the split" (`harness.ts:183`): `status !== 0` fails nothing, and a
     probe that cannot start would then count as proof.
   - `--no-env-file` on the harness's `bun test` (`harness.ts:190`): removing it fails nothing, because cwd `/check`
     already keeps `/work/.env` out.

   One test each, or say in DESIGN that they are belt-and-braces.

7. **NIT: the second of two concurrent OKs after a stale build gets the wrong 409 code.** Both requests carry a fresh
   held-out hash and both find the stale build. The second waits on `FOR UPDATE` (`store-pg.ts:228`) and does not see
   the first's new row in that statement. It then sees that row in the `used` query (`store-pg.ts:230`) and answers
   `state_conflict` ("held-out already used") while a build is running. API.md says the second of two concurrent
   requests gets `already_running`. Re-run the live query after taking the lock, or check `used` against terminal
   builds only.

p45b: sound. I re-read `outcome.ts`: the median is in integer tenths, `m20 * 10 >= e10 * 2 * 8` is exactly ≥ 80%, and
purged weeks are never guessed. Its 17 tests pass.

**Required before PASS:**
- Fix finding 1: `chmod` before `chown`, and an emulator with the container's capability set, red first.
- Fix finding 2: remove the folders a sandbox user made, or record them for a reaper, with a red test.
- Findings 3 and 5 to 7 are recommended. Finding 4 stays with its owners.

VERDICT: CHANGES

### Author response (round 5)

| Finding | What I did | Commits |
|---|---|---|
| 1 MAJOR (`chmod` after `chown` fails with three capabilities) | **Fixed.** Red first: the privileged emulator now honours `--user` and `--cap-add` through `setpriv`. `--user 0:0` gets `--bounding-set=-all,+chown,+setgid,+setuid --inh-caps=-all --no-new-privs`, and any other user gets `--reuid/--regid --clear-groups` with no capability. That alone turned the six privileged tests red with the `EPERM`. The privileged tests now need both `sudo` and `setpriv` and never fall back to full root. The comment at `guard.test.ts:34` is rewritten. Fix: `chmod` before `chown` for the run folder and for the socket. Mutation: putting `chown` first again fails 6 tests | e074daa, f3f704a |
| 2 MAJOR (sandbox-user folders left behind and forgotten) | **Fixed.** Red first: a privileged test (`mkdir tests` and a file as uid 65534 in `/work`; after `destroy()` the root is gone and the id is no longer listed). The round 4 test is replaced: `destroy` never throws on a folder it cannot remove, keeps it in `list(tag)` (also for a new provider, read from disk), and a later `destroy` removes it. Fix: each sandbox folder gets a `sandbox.json` record (id, tag, image, `0600`). `destroy()` removes the containers, then empties `/work` from a cleanup container as each uid that owns files there (`find /work -mindepth 1 -delete`; `--network none --pull never --read-only --cap-drop ALL --security-opt no-new-privileges --pids-limit 256`, only `/work` mounted, labelled with the sandbox id), then removes the folders. The box is forgotten only once removal succeeds. Otherwise the record stays, `list(tag)` reads it from disk, and `destroy(id)` rehydrates from it. The "reaper takes it from there" wording is gone. Mutations: skipping the cleanup container fails the privileged test; dropping the on-disk listing fails the record test | b779b77, aff59bf |
| 3 MINOR (process APIs past the linter) | **Fixed, both layers.** Linter: refuses `getBuiltinModule`, `Bun[...]`, destructuring from `Bun` and aliases of `Bun` (5 new refused cases in `checks.test`). Guard, under the split: `Bun.$`, every `child_process` function (`spawn`, `spawnSync`, `exec*`, `execFile*`, `fork`), `process.dlopen` and `Worker` are pinned to throw, and `process.getBuiltinModule` refuses `worker_threads`/`cluster`. All of this is patched through `require` before the check loads. Privileged test with the cheat tool, 7 routes: `const { $ } = Bun`, `Bun["$"]`, `import("bun")`'s `$`, `getBuiltinModule("node:child_process")`, `require("node:child_process")`, `import("node:child_process")` and `getBuiltinModule("node:worker_threads")`. Each must end `split: true`, status fail, not passed, with the guard's refusal in the output. Note: on Bun 1.4.4, `node:child_process` is built on `Bun.spawn`, so it already reached the broker. Only the three `Bun.$` routes actually let the cheat pass. Pinning the refusal message makes each guard patch fail the test when removed (checked for `Bun.$`, `child_process` and `getBuiltinModule`) | 9f0b0b3, ef39fe7 |
| 4 MINOR (owner actions) | Carried, unchanged, still listed in DESIGN section 7. The `LIVE:` Docker run is the one the setpriv emulation stands in for. It must still run on a Linux engine before m2-07/m2-08 rely on the split | none |
| 5 NIT (root on a caller's word) | **Fixed.** `HARNESS_ARGV` moves to the provider port (`sandbox/provider.ts`, frozen) and is re-exported by `shards.ts`. The Docker provider's `exec` throws `SandboxSpecError` for `harness: true` unless argv is exactly `HARNESS_ARGV` and cwd is `/check`, before any docker call. `runArgv` also requires it before it grants root. Red test: 4 near-miss execs are refused and no docker call is made | 0020d45, f22c894 |
| 6 NIT (two defensive rules unpinned) | Recorded in DESIGN section 7 as belt-and-braces: only exit 3 (`EACCES`) proves the split, and `--no-env-file` on the check's `bun test`. Pinning the first would need an emulator that breaks the probe on purpose; not worth it for a rule that only narrows | fd90c48 |
| 7 NIT (wrong 409 code for the second concurrent OK) | **Fixed.** Red first: a Postgres test, 6 rounds of a stale build followed by two concurrent inserts with the same fresh held-out hash. The loser must be `BuildConflict("already_running")`; before the fix it was `HeldOutUsed` every time. Fix: `insertQueued` reads the live builds again (a new statement, a new snapshot, still `FOR UPDATE`) once it holds the lock, before the `used` check | dd889c4, 177d8df |

Tests: p45a 144 (was 140): 143 pass and 1 skip, the live Docker block, which needs a Docker engine. The 4 new tests are the privileged destroy, the privileged run-time refusals, the harness-exec refusal and the Postgres race. The round 4 destroy test was replaced in place, and the new linter cases extend an existing test. p45b: 17, unchanged. The privileged tests ran here under `sudo` and `setpriv`.

## Round 6

Independent review (Opus 5.5; wrote none of the code and none of rounds 1 to 5), 2026-11-22, branch `port/build-loop` at
`c922b30`. The brief names `8f6ff2d` as the base, but the branch was rebased onto `origin/main` (`9565129`, commit
`7612d68`): `8f6ff2d..HEAD` also holds the eight Wave 1 commits already on main (`services/brain`, `slices/m*`, …),
which are not this port. The port's diff is `9565129..HEAD` (47 files). Focus: `7612d68..HEAD`, the round 5 fixes.

**Read:**
- AGENTS.md (review gate, privacy rules) and CLAUDE.md;
- both SPECs, DESIGN.md, and rounds 1 to 5 with their author responses;
- DATA_MODEL section 1 (member isolation), section 6 (`builds`, `worker_attempts`, `budget_reservations`,
  `build_receipts`, `approvals`), the API.md builds rows, SECURITY_PRIVACY section 13, MIGRATION 5.6;
- all of `harness.ts`, `sandbox/docker.ts`, `sandbox/provider.ts`, `shards.ts`, `attempt.ts`, `loop.ts`,
  `store-pg.ts` (insert, reserve, deploy), the check linter in `checks.ts`, and the SQL's RLS block;
- `git diff 7612d68..HEAD` on `src` and both test folders, and every removed assertion line since `9565129`.

### Runs (this reviewer, DATABASE_URL set, passwordless `sudo` and `setpriv` available, no Docker)

| Command | Result |
|---|---|
| `bash slices/p45a-build-loop/verify.sh` | Slice suite **144 tests across 10 files: 143 pass, 1 skip (`LIVE:` Docker), 0 fail** (min 75). All 24 tags pass: GATE 12, CHECKS 5, HELDOUT 11, TEETH 5, DEFAULT1 1, SHARDS 27, FANOUT 9, STALL 2, LOCK 15, SHIP 4, BUDGET 6, CAP 3, TAMPER 2, PROOF 3, VERDICT 1, SANDBOX 19, INFRA 3, DEPLOY 1, READY 4, TDD 3, STEPS 1, ERROR 1, API 3, RLS 2. Typecheck ok. Scope checked (46 files). With the operator's `DATABASE_URL` the full-suite step fails (see NIT 6); against a disposable `*_test` database: **`p45a-build-loop: PASS`** (exit 0) |
| `bash slices/p45b-measured-saving/verify.sh` | Slice suite **17 tests across 1 file: 17 pass** (min 12). SHIP 3, MEASURE 6, FLAG 2, MONTH 1, OUTCOME 2, FIGURE 3. Scope checked (24 files). Same full-suite note; against the disposable database: **`p45b-measured-saving: PASS`** (exit 0) |
| `bun test` (full suite) | Operator's `DATABASE_URL`: **366 tests ran, 350 pass, 1 skip, 15 fail**. All 15 are W1-C's `packages/db/tests/m1-03-tenancy-rls/*` ("refusing to reset a database that is not disposable", `packages/testkit/src/pg.ts:252`), none is the builder's. Against a scratch database `offload_r6_test` (created, then dropped): **448 tests across 66 files, 447 pass, 1 skip, 0 fail** |
| `bash scripts/verify-all.sh` | Operator's `DATABASE_URL`: exit 1 at `bun test` (the 15 W1-C failures). Disposable database: exit 1 at `slices` (`m1-01-durable-spike` scope, a done slice of another stream). Disposable database plus `SLICE_UPSTREAM=origin/main`: **`verify-all: green`** (exit 0): typecheck, 448 tests (447 pass, 1 skip), license boundary ok, slices ok (15 specs; p45a PASS, p45b PASS), doc links ok (79 files), copy ok, secrets ok, workflows ok (3 files), Swift skipped (needs macOS) |
| Privileged tests | `sudo -n` and `setpriv` work, so every `(privileged)` test ran under the container's real capability set. The only skip is `LIVE:` |
| Scope (by hand, `9565129..HEAD`) | 47 files, all in `paths_in_scope`: `services/builder/**`, `packages/hours-saved/src/measured/**`, its test folder and `src/index.ts`, both slice folders, NOTICE, docs/API.md, DATA_MODEL.md, MIGRATION.md. Nothing under `packages/{db,contracts,policy,testkit,routine-sdk,connectors-sdk}`, `services/{api,runtime,broker,brain}`, `apps`, `ee`, `.github` or `docs/adr`. `bun.lock` and `package.json` unchanged. NOTICE lists superpowers (MIT text included) and the ideas-only entries |
| Hygiene | No `console.*` in `src`. After all runs: no `p45a%` schema or role left in Postgres, the scratch database dropped, `git status` clean before this file was written |

### Mutation checks (tests really fail without the code)

`/tmp/r6-mut/mut.sh` (outside the repo) changed one guard with `perl -0pi`, checked the file really changed, ran both
slice folders, and restored the file with `git checkout --`. No stash. `git status` was clean after every run.

**The round 5 fixes**

| Mutation | Failing tests |
|---|---|
| `chown` before `chmod` again on the run folder (`harness.ts:138`) | 7 (every privileged shard test) |
| `destroy` skips the cleanup container (`docker.ts:302`) | 1 (`SANDBOX: (privileged) destroy removes folders and files a sandbox user made`) |
| `list(tag)` ignores the on-disk records (`docker.ts:343`) | 1 (`SANDBOX: destroy never throws … keeps it listed (on disk)`) |
| the guard does not pin `Bun.$` (`harness.ts:74`) | 1 (`SHARDS: (privileged) a check that starts the tool outside Bun.spawn/spawnSync`) |
| `exec` accepts `harness: true` on any argv (`docker.ts:266`) | 1 (`SANDBOX: harness: true is refused unless …`) |
| `insertQueued` reads the live builds once (`store-pg.ts:96`) | 1 (`LOCK: (Postgres) after a stale build, the second of two concurrent OKs …`) |
| `destroy` forgets the box before removing it | 0: equivalent, the on-disk record still finds it |
| linter rule "destructuring from Bun" removed (`checks.ts:92`) | 0: equivalent, the alias rule (`checks.ts:93`) catches the same lines |

**473cafb and the other security fixes (all still fail)**

| Mutation | Failing tests |
|---|---|
| `bun test` with cwd `/work` (`harness.ts:210`) | 13 (`SHARDS:` planted bunfig preload, node_modules, tsconfig paths, package.json imports, `.env`, …) |
| guard `onLoad` off / `--config=/check/bunfig.toml` dropped | 2 / 2 |
| `--network none` → `bridge` / no `--cap-drop ALL` / `/check` read-write / no `--read-only` | 1 / 2 / 2 / 1 |
| shard passes on exit 0 alone, proof ignored (`shards.ts:73`) | 2 (`PROOF:`) |
| split proof not required (`shards.ts:72`) | 3 |
| docker exit 125 treated as a result, not infra (`docker.ts:278`) | 1 |
| approval TTL off / single use off | 2 / 48 |
| OK's hash gate off (`loop.ts:79`) | 1 (`GATE:` wrong brief hash, 403) |
| Postgres reservation ceiling ×100 / its `FOR UPDATE` removed | 2 / 2 (`CAP:`) |
| held-out shard left out of the teeth gate (`loop.ts:183`) | 4 |
| held-out text appended to the fan-out feedback (`loop.ts:297`) | 1 (`FANOUT:`) |
| fan-out not awaited (`loop.ts:301`) | 18 |
| deploy once off in Postgres (`store-pg.ts:209`) | 1 (`SHIP:`) |
| `..` allowed in a sandbox path (`provider.ts:92`) | 1 |
| stale recovery off (memory store) | 10 |

### Test history

- Red before green holds for every round 5 fix: `e074daa` < `f3f704a`, `b779b77` < `aff59bf`, `9f0b0b3` < `ef39fe7`,
  `0020d45` < `f22c894`, `dd889c4` < `177d8df`. The mutations above show each new test fails without its fix.
- Removed assertion lines since round 5:
  - `e074daa` drops `expect(cmd[0]).toBe("bun")` inside the test emulator, because the emulator now also runs the
    cleanup container's `find`. The harness argv stays pinned by `docker.test.ts` (`SANDBOX: the docker argv is exact`,
    and the `HARNESS_ARGV` equality at `docker.test.ts:47`). Not a weakening.
  - `b779b77` replaces "destroy forgets a sandbox …" with "destroy never throws … keeps it listed", the behaviour round 5
    finding 2 asked for. Stricter, not weaker.
  - `ef39fe7` turns the bypass loop into one `toEqual` over all cases, adds two cases and pins the refusal message.
    Stricter.
- **No assertion is weakened.** No `.skip`, `.todo`, `.only` or `it(`; the skips are `describe.skipIf(!dockerUp)`
  (`LIVE:`) and `test.skipIf(!sudoOk)` (they ran here).
- Every MIGRATION 5.6 carry test is present in v2 words (rounds 1 to 5 mapped them; nothing since removed one). Every
  builder row of SECURITY section 13 has a test; "no registry reachable" is still only the never-run `LIVE:` test.

### My own checks (scratch files in `/tmp/r6-scratch`; nothing in the repo changed)

1. **A sandbox user's read-only folder.** I copied the test emulator into a scratch test, made `work/tests/` with a
   file in it as uid 65534 (`setpriv --reuid=65534`), then called `destroy()` on a split provider:
   - `0755 tests/` (control): the sandbox root is gone and no longer listed;
   - `chmod 555 tests/`: **the root is left behind** (and listed);
   - `chmod 000 tests/`: **the root is left behind** (and listed).
   The cleanup container runs `find /work -mindepth 1 -delete` as the owner, and the owner cannot unlink entries in a
   folder it made non-writable or unreadable without first changing its mode (finding 1).
2. **The second OK without a stale build** (by reading `store-pg.ts:93-104`, not reproduced; the window is two round
   trips). With no live row, `SELECT … FOR UPDATE` locks nothing and does not wait on another transaction's
   uncommitted insert (finding 2).
3. **`harness: true` with a caller's environment** (by reading). `exec` pins argv and cwd (`docker.ts:32`, `:266`),
   but `OFFLOAD_CHECK_DIR` and `OFFLOAD_WS` are allowlisted names (`provider.ts:82`) and the harness takes `CHECK`
   from them (`harness.ts:126`) for `--config`, cwd and the test file (`harness.ts:209-210`) (finding 3).

### Round 5 findings, status

| Finding | Status |
|---|---|
| 1 MAJOR (`chmod` after `chown`) | **Fixed** (`harness.ts:138`, `:186-187`). The emulator now applies `--user` and `--cap-add` through `setpriv` (`guard.test.ts:84-89`) and the privileged tests need `setpriv` (`guard.test.ts:304-313`). The mutation fails 7 tests |
| 2 MAJOR (sandbox-user folders left and forgotten) | **Fixed for the normal path** (cleanup container `docker.ts:302-308`, record `docker.ts:100`, `list` from disk `docker.ts:343`, rehydrate `docker.ts:296`). A worker that makes its own folder read-only still defeats it; the folder stays recorded (finding 1) |
| 3 MINOR (process APIs past the linter) | **Fixed** in both layers (`checks.ts:89-93`, `harness.ts:69-86`), with 7 run-time cases |
| 4 MINOR (owner actions) | Carried (finding 5) |
| 5 NIT (root on a caller's word) | **Fixed** for argv and cwd (`docker.ts:32`, `:227`, `:266`). The environment is still the caller's (finding 3) |
| 6 NIT (two unpinned defensive rules) | Recorded in DESIGN section 7 as belt-and-braces. Accepted |
| 7 NIT (wrong 409 after a stale build) | **Fixed** (`store-pg.ts:95-100`) with a Postgres test. The no-stale variant remains (finding 2) |

### Findings

1. **MINOR: a sandbox user can still make its sandbox folder unremovable.** `destroy()` empties `/work` as each
   foreign owner with `find /work -mindepth 1 -delete` (`docker.ts:321-337`), and `find` never changes a mode.
   - Evidence: my check 1. A folder in `/work` with mode `0555` or `0000`, owned by 65534, survives the cleanup
     container. The host `rmSync` then fails (`docker.ts:309-317`), and the sandbox root, with the artifact and any
     fixture copies the worker made, stays on the builder host.
   - Who can do it: any worker (`chmod 555 tests`, or a test of the "read-only folder" edge that `TDD_INSTRUCTIONS`
     asks for, `attempt.ts:19-23`), and the built tool in a verification sandbox, which also runs as 65534 in
     `/work`.
   - Why only MINOR: it fails closed. The record keeps the folder in `list(tag)` (round 5's fix works), the folder is
     private to the builder's uid, and nothing passes that should not. But SANDBOX's "temps removed" does not hold
     against the party the sandbox exists to contain, and every later `destroy` or reaper call fails the same way.
   - Required fix:
     - Let the owner restore its own modes before deleting, in the same cleanup container. For example, entrypoint
       `sh`, args `-c 'chmod -R u+rwX /work 2>/dev/null; find /work -mindepth 1 -delete'`. The owner may `chmod` its own
       files with no capability, and `chmod -R` changes a folder before it reads it.
     - Red test first: the privileged destroy test with `chmod 555` and `chmod 000` cases.

2. **NIT: the second of two concurrent OKs can still get `state_conflict` when there is no stale build.**
   - Evidence (`store-pg.ts:95-102`): with no live row, both live queries lock nothing. If the first OK commits
     between the second OK's second live query and its `used` query, the second sees the first's row in `used` and
     answers `HeldOutUsed` (409 `state_conflict`). API.md (OK, build row) promises `already_running` to the second of
     two concurrent requests.
   - Both answers are 409 and nothing unsafe happens. The memory store is not affected.
   - Required fix: when `used` is true, run the live query once more and answer `already_running` if a fresh live build
     exists now. Do not just exclude live builds from `used`: a stale build being recovered here still used its
     held-out hash.

3. **NIT: `harness: true` pins the argv and the cwd, but not the environment.**
   - `OFFLOAD_CHECK_DIR` and `OFFLOAD_WS` are allowlisted (`provider.ts:82`). A worker holding the provider through
     `WorkerTurn` (`attempt.ts:25-27`, m2-07) can run `exec({ argv: HARNESS_ARGV, cwd: "/check", harness: true, env:
     { OFFLOAD_CHECK_DIR: "/work" } })`. The root harness then runs `bun test --config=/work/bunfig.toml`, which
     preloads the worker's own code as `OFFLOAD_CHECK_UID`, the builder's host uid (`harness.ts:126`, `:209-210`).
   - This gains nothing today: it is the worker's own sandbox, `setuid` drops the three capabilities, and `/check` is
     readable there anyway. But it is the same "privilege on a caller's word" round 5 NIT 5 closed for argv.
   - Required fix: on a harness exec, the provider refuses any `env` that differs from `HARNESS_ENV`, or sets
     `HARNESS_ENV` itself. Alternatively, m2-07's worker gets a narrowed handle without `harness`.

4. **NIT: the on-disk records are trusted as found.**
   - `onDisk()` (`docker.ts:106-123`) reads every `offload-sbx-*/sandbox.json` under the provider root. That root
     defaults to `os.tmpdir()` (`docker.ts:75`), which other host users share.
   - `destroy()` then passes the record's `image` to `docker run` (`docker.ts:296`, `:304`, `:335`) and follows
     `work` wherever the entry points.
   - Only a local host user can plant a record, and only a reaper-style `list` then `destroy` reaches it; no build path
     does today.
   - Required fix, before the reaper (m2-08) uses `list`:
     - check `record.id === "sbx_" + sha256(root).slice(0, 16)`;
     - skip symlinked entries;
     - use the configured image, not the record's;
     - default the root to a private builder folder.

5. **MINOR (owner actions, carried, unchanged in DESIGN section 7):**
   - The `LIVE:` Docker run has never run. It is the only proof of the production path: root PID 1 with three
     capabilities under `no-new-privileges`, `chown` on the bind mount, the broker socket, network and registry
     denial, `swept`, and now the cleanup container.
   - `LOCAL:` tests and `redirect: "error"` for m5-03.
   - The winner order (bytes against ADR 0029's smallest diff).
   - Sandbox-time billing (m2-08).
   - Start before claim (W1-C).
   - The image digest pin (S4).

6. **NIT (environment and shared scripts, nothing in this slice to change):**
   - With the `DATABASE_URL` the operator set, W1-C's `packages/db` tests refuse the database (it is neither `*_test`
     nor commented `offload:disposable`). So both slices' `verify.sh` print `FAIL full suite exited 1`, and
     `verify-all.sh` stops at `bun test`.
   - `verify-all.sh` also needs `SLICE_UPSTREAM=origin/main` for `m1-01-durable-spike`'s scope check after the merge.
   - Both are green with a disposable database and that variable.
   - Separately, `verify.sh`'s scope step checks `9565129..1f4932f` (up to the commit that set `status: done`), so
     the review-round commits after it are not scope-checked by the script. I checked `9565129..HEAD` by hand: in
     scope.
   - The operator should run the gate with a disposable database. The scope-range question belongs to
     `scripts/lib/slice-changes.sh`, outside this slice.

p45b: unchanged since round 5 (`git diff 7612d68..HEAD -- packages/hours-saved` is empty). Its 17 tests pass.

**Required before PASS:** none. No BLOCKER or MAJOR is open. Finding 1 is recommended now (a one-line entrypoint
change with a red test). Findings 2 to 4 and 6 are recommended. Finding 5 stays with its owners, and the `LIVE:` run is
required before m2-07/m2-08 rely on the user split.

VERDICT: PASS
