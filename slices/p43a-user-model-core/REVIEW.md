# Review: p43a-user-model-core and p43b-user-model-store-api (port of old PR #43)

Reviews of the stacked slices on branch `port/brain-user-model`. Each round is appended; author responses go under the
round they answer.

## Round 1

Independent reviewer (Claude Code, Opus 5.5). It did not write this code. Read: AGENTS.md (review gate), CLAUDE.md,
both SPECs, DESIGN.md, ADR 0003, 0013, 0019, DATA_MODEL 1 and 4, API.md (error envelope, Figure, profile, records,
review), ARCHITECTURE 5 and 6, SECURITY_PRIVACY 13, MIGRATION 5.4, `git diff 8f6ff2d..HEAD` (53 files), every test
file, and the old code at `/workspace/offload-wsB` (`f9e2793`, read only). Reviewed at `36b5981`.

### Runs (DATABASE_URL set, local Postgres 17)

| Command | Result |
|---|---|
| `bash scripts/verify-all.sh` | `verify-all: green`. Full suite **137 pass, 0 fail**, 34 files, 2565 `expect()` calls. Both done slices PASS, slices lint ok (10 specs), doc links ok (69 files), copy ok, secrets ok, license boundary ok. |
| `bash slices/p43a-user-model-core/verify.sh` | `p43a-user-model-core: PASS`. Slice suite **61 pass, 0 fail**, 7 files (`min_tests` 55). LEDGER 7, OBSERVE 2, DAY 5, LEAKS 2, WEEK 4, THEIL-SEN 2, MONTH 2, QUARTER 1, NARRATIVE 4, SCORE 8, PROPOSE 5, LONG-TERM 2, INVALIDATE 2, SUPERSEDE 2, REVISE 1, MERGE 1, PROFILE 5, PROMPTS 2, PRIVACY 1, REVIEW 3. Full suite 137/137. Scope checked (53 files). |
| `bash slices/p43b-user-model-store-api/verify.sh` | `p43b-user-model-store-api: PASS`. Slice suite **26 pass, 0 fail**, 4 files (`min_tests` 20). PROFILE 5, API 9, PRIVACY 1, RLS 4, MERGE 1, INVALIDATE 2, STORE 4. Full suite 137/137. Scope checked (28 files). |

No skipped, `todo` or `.only` tests. The Postgres files use `describe.skipIf(!HAS_DB)`, and `verify.sh` has
`NEEDS_POSTGRES=1`, so p43b fails fast without a database instead of passing vacuously. After every run, including the
mutation runs below: 0 leftover `p43b_*` schemas and 0 `p43b_app_*` roles.

### 1. Tests fail without the code (mutation check)

Twelve guards were broken one at a time. After each, the covering tests were run and the file was restored with
`git checkout -- <file>`. `git status` was clean after every step.

| # | Change (file:line) | Result |
|---|---|---|
| M1 | Dropped the restrictive `member_isolation` policy (`sql/0001_user_model.sql:234-236`) | 3 RLS tests fail |
| M2 | Repository leak guard made a no-op (`src/store/repository.ts:39`) | STORE leak test fails |
| M3 | `bunRunInTenant` without `SET LOCAL ROLE` (`src/store/tenant.ts:73`), so queries run as the superuser session | 4 fail (3 RLS, INVALIDATE no-DELETE) |
| M4 | Old bug: `invalid_at = fresh valid_at` (`src/user-model/merge.ts:178`) | SUPERSEDE fails |
| M5 | Old bug: staleness on the wall clock (`merge.ts:189`) | INVALIDATE gap test fails |
| M6 | `checkNarrative` harvests digits from every string, as the old code did (`src/records/narrative.ts:260,275`) | 2 NARRATIVE tests fail |
| M7 | `<user_context>` keeps `<` and `>` (`src/understanding/context.ts:211`) | PROMPTS fails |
| M8 | `safeName` keeps digits and emails (`src/user-model/names.ts:81-84`) | 6 fail: LEAKS ×2, PRIVACY, REVIEW, and the p43b privacy file's setup (the repository guard refuses the write: defence in depth works) |
| M9 | Old bug: `not_now` never expires (`src/opportunities/score.ts:143`) | SCORE fails |
| M10 | Old bug: empty name word sets match (`src/user-model/ledger.ts:159`) | LEDGER fails |
| M11 | Dropped the `goals_max_active` trigger (`sql:48-49`) | PROFILE fourth-goal test fails |
| M12 | The checked model sentence is never stored (`src/store/job.ts:249`) | API narrative test fails |

### 2. Test changes after the red commits

Red commits: `8c22dc8` (p43a), `adff86b` (p43b), `c69e88e` (review findings). Test edits after them:
- `935f14e` (green) adds one test, `API: the review sentence is the stored narrative …`, and changes no existing
  assertion. M12 shows the test catches the failure it targets, but it was never seen red (finding 6).
- `c69e88e` adds 5 tests and changes one assertion in `weeks.test.ts`: `"It took 1,200 minutes over 3 days."` goes
  from `ok: true` to `ok: false`. This **tightens** the test (ADR 0003) and is recorded under the p43a SPEC's
  "Scope changes".
- `adff86b` adds an email-in-goal case to the p43a PROFILE validation test (tightens).

**No assertion was weakened.** Every mandatory red test in MIGRATION 5.4 exists with its tag. I matched them by name:
LEDGER ×4, DAY, LEAKS, WEEK ×2, THEIL-SEN, MONTH, SCORE ×3, PROPOSE ×2, SUPERSEDE, INVALIDATE, MERGE, PROFILE ×2,
PROMPTS, PRIVACY (in both slices), and `API: GET /v1/review/week?w=`. Each asserts behaviour against fixture or
computed values, not tautologies. The one conditional (`weeks.test.ts`, NARRATIVE dates test, `if (values.has(n))
continue`) still asserts 3 of its 5 probe numbers (45, 2026, 100), so it is not vacuous. Of the 55 old tests, those
dropped (CLI ×2, WORKFLOWS, SUGGESTIONS, EDGES, OBSERVE transitions, MIGRATE `user-context.json`, sealed-file STORE ×4,
`/memory/model`) all match MIGRATION 5.4 "Drop" or DESIGN section 6.

### 3. Correctness against the ADRs and docs

- Ledger match order, episodes (focus block ≥ 25 min), persistence (75% and 8/13), Theil-Sen over week-index points
  with 3 or more weeks, baseline over the 8 calendar weeks before, and the proposition confidence, decay, supersede
  and stale rules match ARCHITECTURE 5 and the SPEC. The score formula, `paybackWeeks`, the drain boost, the
  confidence source and `declinePenalty` (`score.ts:101-109,139-144`) match ARCHITECTURE 6.
- Tables, columns and keys match DATA_MODEL 4 plus the documented additions (`goals.position`, `episodes.day`,
  week/month/quarter extras, `opportunities.goal_id`, the 5-column `figure_index` key, all recorded in DATA_MODEL and
  the SPEC's "Scope changes"). Figure shape and id match API.md. Error codes and statuses (400 `invalid_request` and
  `schema_invalid`, 404, 413 `too_large`, 422 `leak_detected`, 500) are in API.md's closed list. Routes and shapes
  match the API.md additions.
- Bi-temporal: `invalid_at = max(old.valid_at, new.valid_at)`. The table has `CHECK (invalid_at >= valid_at)` and one
  current version per key (`sql:105,108`). Nothing is deleted. `offload_app` has no DELETE except on `figure_index`
  and `opportunities` (tested).
- Every shown number is a code Figure. The only model output is the weekly sentence, gated by `checkNarrative`.
  Proposition confidence never enters ranking.

### 4. Security and privacy

- RLS: `ENABLE` + `FORCE`, `tenant_isolation` and restrictive `member_isolation` on all 12 tables. Tests run as a
  `NOLOGIN NOBYPASSRLS` non-owner role (`tests/p43b-user-model-store-api/db.ts:37`, ownership asserted in
  `privacy-rls.test.ts:143-144`). Member A2 and tenant B read zero rows, and an unset tenant reads zero. A cross-member
  or cross-tenant INSERT fails (USING doubles as WITH CHECK). The tenant and member come only from `auth`
  (`handlers.ts:145`).
- SQL injection: every value is a bind parameter. Interpolated text is either a constant (`TID`, `MID`, `OWN`,
  `ROLLUP_TABLE`) or passes `ident()` (`tenant.ts:59-63`, `migrate.ts:22-23`).
- No raw observation text in R-model tables. Names are scrubbed (`names.ts`), and every write except validated
  review answers goes through the leak guard. The PRIVACY tests dump every table as the superuser and search for the
  fixture's titles, URLs and emails. Observation ids appear only as evidence (`episodes.evidence`, figure `evidence`),
  as DATA_MODEL 4 and ADR 0003/0019 require. They are absent from propositions, ledger, profiles, goals and answers
  (`privacy-rls.test.ts:130-131`, `review.test.ts:216`). Ledger signatures are hashed.
- Goals reach a prompt only inside `<user_context>` (`narrative.ts:301`, PROMPTS). There is no network I/O inside a
  tenant transaction (`job.ts:241-252`) and no log lines (`console.*` appears nowhere in `src/`).

### 5. Scope

All 53 changed files match `paths_in_scope`. There are no edits under `packages/`, `services/api`, `services/runtime`,
`services/broker`, `services/builder`, `apps/`, `ee/`, `.github/` or `docs/adr/`. `package.json` and `bun.lock` are
unchanged, and there is no new dependency. NOTICE moves gum (MIT) and graphiti (Apache-2.0) from "Planned" to
"included", naming the files that use their ideas. Deleting `services/brain/tests/smoke.test.ts` is in the p43a
contract.

### Findings

1. **MINOR. A model sentence with a link or an email makes the narrative step throw instead of falling back.**
   `checkNarrative` only checks numbers, so `writeWeekSentence` returns `source: "model"` for "Read more at
   https://evil.example/now for tips." or "Ask dana@fund.example about it." (probe at `36b5981`). Then
   `writeWeekNarrative` calls `setWeekNarrative`, whose guard throws `LeakError` (`repository.ts:208`,
   `job.ts:249`), so the durable step fails and retries the model. Privacy holds, because nothing is stored.
   *Fix:* in `writeWeekSentence` (`narrative.ts:328`), fall back to the code sentence when `hasLeak(sentence)`. Add a
   NARRATIVE test.
2. **MINOR. Goals and role accept a bare `www.` link.** API.md says "no `<`, `>`, email address or link", but
   `line()` (`profile.ts:72`) uses `hasLeak`, which allows bare hosts (`names.ts:105-107`). `{ goals: ["Grow signups
   on www.example.com"] }` is accepted, and the goal text reaches the model inside `<user_context>`. *Fix:* a
   stricter check for profile text (refuse `www.` and host-with-TLD tokens), plus a PROFILE case.
3. **MINOR. The old content-type check was dropped without a note.** Old `jsonBody`
   (`brain/src/api/s14-routes.ts:40` at `f9e2793`) refused non-`application/json` bodies. `readJson`
   (`handlers.ts:42-51`) parses any type, and a `text/plain` PATCH returns 200 (probe). CSRF belongs to
   `services/api` (API.md; SPEC "Out of scope"), so this is defence in depth only. *Fix:* keep the check (400
   `invalid_request`), or record the drop in DESIGN.md section 6.
4. **MINOR. Days come from `window.timezone`; the routes use `profiles.timezone`.** Day records, the ledger and
   observations use the window's zone (`day-record.ts:274`, `ledger.ts:181`, `observe.ts:269`). "Future week" uses the
   profile's (`handlers.ts:81-84`). `runMemberUpdate` loads the profile (`job.ts:187`) but never checks that the two
   agree. DATA_MODEL 1 says days are in `profiles.timezone`. *Fix:* refuse a window whose timezone differs from the
   profile's (or use the profile's), and test it.
5. **MINOR. Stale episodes on re-analysis, and an unstated id assumption.** A re-analysed day with different instance
   ids leaves the old `episodes` rows: there is no DELETE grant, and R-model data is kept until forget, so DESIGN
   section 7's "the forget and retention paths clean them" does not hold for retention. DATA_MODEL says the Today
   grid is computed from episodes at read time, so such rows would be double counted. Separately, `ep_` + instance id
   is upserted by id (`day-record.ts:301`, `repository.ts:134`), so an id reused on another day would overwrite that
   episode. *Fix:* state in DATA_MODEL (or the SPEC) that readers select a day's episodes through
   `day_records.episode_ids`, correct the DESIGN sentence, and document in `ports.ts` that `WindowInstance.id` is
   globally unique (`task_instances.id` is a uuid).
6. **MINOR (process). Status and review record.** Both SPECs were set to `status: done`, and DESIGN.md section 2 cites
   "Found by the independent review (fixed, with tests)" (`c69e88e`, `36b5981`), but no review record existed before
   this file. Definition of done item 7 needs a passed review first. One API test was added in the green commit
   `935f14e` and never seen red (it does catch a regression, M12). *Fix:* this file is the record from now on. Write
   future tests in the red commit.
7. **NIT.** `readJson` buffers the whole body before the 64 KiB check (`handlers.ts:43-44`). The old code did the
   same. `services/api` should cap by `Content-Length` or a stream limit when it mounts the handlers.
8. **NIT. Glossary.** "Left alone" (GLOSSARY:136) says `never` sets state `left_alone`, but DATA_MODEL lists `never`
   as its own state, and `repository.ts:314` maps `never` to `never`. The docs disagree; pick one. "Focus block",
   "time share", "revision group" and "track record" are used but have no glossary entry (AGENTS: new terms go in the
   glossary first). `docs/GLOSSARY.md` is not in `paths_in_scope`, so adding them needs a scope-change note.
9. **NIT.** ARCHITECTURE 5 says focus-block gaps are "under 2 min"; the SPEC and `day-record.ts:317` use ≤ 2 min.
10. **NIT.** The cross-member INSERT test covers `review_answers` only (`privacy-rls.test.ts:163-177`). The policies
    come from one loop, so the risk is low, but looping over `MEMBER_ISOLATED_TABLES` would make the test complete.

No BLOCKER or MAJOR finding. The MINOR items can be fixed in a follow-up round on this branch.

VERDICT: PASS

### Author response (round 1)

Author: Claude Code (Opus 5.5), the author of both slices. Every behaviour change below had its test committed and seen
failing before the fix. Red commits `fd2454f` (p43a) and `3a2edd6` (p43b); fixes `b1dbd47` (p43a) and `81f67c2`
(p43b); docs `4b18a06`. After the round: `p43a-user-model-core: PASS` (63 tests, was 61), `p43b-user-model-store-api:
PASS` (30 tests, was 26), full suite 143 pass, `verify-all: green`, 0 leftover test schemas or roles. Scope is
unchanged.

1. **Fixed.** `writeWeekSentence` falls back to the code sentence when the model sentence holds a link or an email
   (`hasLeak`), so `writeWeekNarrative` never reaches the repository guard with one. New test `NARRATIVE: a model
   sentence with a link or an email address falls back to the code sentence` (scheme link, email, `www.` link with a
   path; each passes `checkNarrative` on its own, so the test isolates the new rule). Red at `fd2454f`.
2. **Fixed.** New `hasLink` in `names.ts`: `hasLeak` plus `www.` and host names ending in a common web suffix
   (`acme.com`); profile `line()` uses it for goals, role and industry. `Node.js` stays allowed (no web suffix). The
   PROFILE validation test gained `www.example.com` and `acme.com` cases and a `Learn Node.js` goal in the accepted
   case. Red at `fd2454f`. API.md states the rule.
3. **Fixed (kept the old check).** `readJson` requires `application/json` (parameters and case allowed) on `PATCH
   /v1/profile` and `POST /v1/review/answers`, else 400 `invalid_request`. New test `API: writes need a JSON content
   type`; the privacy file's setup now sends the header. Red at `3a2edd6`. API.md updated.
4. **Fixed.** `runMemberUpdate` throws `TimezoneMismatchError` before any read-modify-write when the window's timezone
   differs from `profiles.timezone`. New test `STORE: the job refuses a window whose timezone is not the profile's, and
   stores nothing` (then runs the same week in the profile's zone and stores it). Red at `3a2edd6`. DATA_MODEL,
   `ports.ts` and DESIGN say so.
5. **Fixed (docs).** DATA_MODEL: a day's episodes are read through `day_records.episode_ids`, never by `episodes.day`
   alone; orphans stay until forget. DESIGN section 7: the retention sentence was wrong and is corrected. `ports.ts`:
   `WindowInstance.id` (and span ids) must be unique for the member, because episodes are upserted by `ep_` + id.
   No behaviour change, so no test.
6. **Accepted.** This file is the review record; `status: done` stands on this round's PASS (definition of done item
   7). The narrative test added in `935f14e` was not seen red then; your mutation M12 shows it fails without the code.
   Every test in this round went red first, in its own commit.
7. **Fixed.** `readJson` refuses a declared `Content-Length` over 64 KiB, then reads the body as a stream and cancels
   it past the cap. New test `API: an oversized body is 413 too_large and is not read to the end` (a 100 KiB stream;
   before the fix all 100 chunks were read). Red at `3a2edd6`. `services/api` should still cap at the edge.
8. **Deferred (scope).** `docs/GLOSSARY.md` is outside both slices' `paths_in_scope`, and this round keeps scope
   unchanged. The code follows DATA_MODEL, the table of record: `never` → state `never`, `leave_alone` → `left_alone`.
   Proposed glossary fix for a docs slice that owns it: "Left alone" is set by `leave_alone`; `never` has its own
   state; add "Focus block", "Time share", "Revision group" and "Track record".
9. **Fixed.** Focus blocks now join spans only across gaps **under** 2 minutes, as ARCHITECTURE 5 says
   (`day-record.ts`); the SPEC contract and the figure's arithmetic text say "under". New test `DAY: a focus block joins
   spans of one task only across gaps under 2 minutes` (119 s joins, 120 s splits). Red at `fd2454f`.
10. **Done (coverage).** New test `RLS: in every table, a copy of member A1's row cannot be inserted by member A2 or by
    tenant B` loops over `MEMBER_ISOLATED_TABLES` with `jsonb_populate_record`. It passed on first run, as expected:
    it adds coverage, not a behaviour change.

## Round 2

Independent reviewer (Claude Code, Opus 5.5). It did not write this code. Reviewed at `39af2e3`. Read: AGENTS.md (review
gate), CLAUDE.md, both SPECs, DESIGN.md, ADR 0003, 0013, 0019, DATA_MODEL 1 and 4, API.md (profile, records, review),
ARCHITECTURE 5 and 6, SECURITY_PRIVACY 13, MIGRATION 5.4, `git diff 8f6ff2d..HEAD` (54 files), every test file, the
round-1 commits (`fd2454f`, `b1dbd47`, `3a2edd6`, `81f67c2`, `4b18a06`), and the old code at `/workspace/offload-wsB`
(`f9e2793`, read only: `memory/seal.ts` `assertDerivedOnly`, `api/s14-routes.ts`, `api/workflow-routes.ts`).

### Runs (DATABASE_URL set, local Postgres 17)

| Command | Result |
|---|---|
| `bash scripts/verify-all.sh` | `verify-all: green`. Full suite **143 pass, 0 fail**, 34 files, 2621 `expect()` calls. Both done slices PASS; slices lint ok (10 specs), doc links ok (70 files), copy ok, secrets ok, license boundary ok, workflows ok. |
| `bash slices/p43a-user-model-core/verify.sh` | `p43a-user-model-core: PASS`. Slice suite **63 pass, 0 fail**, 7 files (`min_tests` 55). LEDGER 7, OBSERVE 2, DAY 6, LEAKS 2, WEEK 4, THEIL-SEN 2, MONTH 2, QUARTER 1, NARRATIVE 5, SCORE 8, PROPOSE 5, LONG-TERM 2, INVALIDATE 2, SUPERSEDE 2, REVISE 1, MERGE 1, PROFILE 5, PROMPTS 2, PRIVACY 1, REVIEW 3. Full suite 143/143. Scope checked (54 files). |
| `bash slices/p43b-user-model-store-api/verify.sh` | `p43b-user-model-store-api: PASS`. Slice suite **30 pass, 0 fail**, 4 files (`min_tests` 20). PROFILE 5, API 11, PRIVACY 1, RLS 5, MERGE 1, INVALIDATE 2, STORE 5. Full suite 143/143. Scope checked (31 files). |

No `skip`, `todo` or `.only`. After every run, mutation runs included: 0 leftover `p43b%` schemas, 0 `p43b%` roles.

### 1. Tests fail without the code (mutation check)

Each change was made alone, the covering test file was run, and the file was restored with `git checkout -- <file>`.
`git status` was clean after the last one.

| # | Change (file:line) | Result |
|---|---|---|
| R1 | `writeWeekSentence` without the `hasLeak` fallback (`src/records/narrative.ts:80`) | NARRATIVE link/email test fails |
| R2 | Profile `line()` uses `hasLeak` instead of `hasLink` (`src/profile/profile.ts:72`) | PROFILE validation test fails |
| R3 | `readJson` without the content-type check (`src/http/handlers.ts:45`) | API content-type test fails |
| R4 | `runMemberUpdate` without the timezone check (`src/store/job.ts:41`) | STORE timezone test fails |
| R5 | `readJson` without the stream cap (`handlers.ts:56`) | API 413 test fails |
| R6 | Focus-block gap `<=` instead of `<` (`src/records/day-record.ts:105`) | DAY gap test fails |
| M-A | `opportunities` left out of the RLS loop (`sql/0001_user_model.sql:227-228`) | p43b privacy file fails in setup |
| M-B | `member_isolation` skipped for `episodes` only (`sql:234-236`) | 3 RLS tests fail, including the new per-table INSERT test |
| M-C | DELETE granted on `episodes` and `day_records` (`sql:240`) | INVALIDATE no-DELETE test fails (plus 3 STORE) |
| M-D | Declared `Content-Length` check removed (`handlers.ts:47`) | **no test fails** (finding 4) |

### 2. Test changes after the red commits

Test files changed only in `8c22dc8`, `adff86b`, `935f14e`, `c69e88e`, `fd2454f` and `3a2edd6`; none after the last
red commit. Every removed test line since the first red commit (`git show <c> -- services/brain/tests | grep '^-'`):
an unused import (`935f14e`, `c69e88e`); `"It took 1,200 minutes over 3 days."` from `ok: true` to `ok: false`
(tightened, recorded under Scope changes); the accepted PROFILE case gained `Learn Node.js` (`fd2454f`, tightened:
it pins the false-positive edge); the privacy file's setup now sends `content-type: application/json` (`3a2edd6`,
needed by the new rule; the setup still asserts the same data). **No assertion was weakened.** The round-1 tests went
red first in their own commits (R1 to R6 above show each catches its regression). The mandatory list of MIGRATION 5.4
is present by name, as round 1 found; nothing was removed since.

### 3. Correctness

The round-1 changes match the docs: content type and 413 (API.md user model shapes), `TimezoneMismatchError` before
any write (DATA_MODEL 1 and 4), episodes read through `day_records.episode_ids` (DATA_MODEL 4), gaps under 2 minutes
(ARCHITECTURE 5). RLS policies are exactly ADR 0013's text. Nothing in round 1 changed tables, shapes or status codes
beyond API.md's closed list.

### 4. Security and privacy

Re-checked at `39af2e3`: RLS as a `NOBYPASSRLS` non-owner role, member and tenant walls on all 12 tables (now with a
per-table INSERT test), bind parameters everywhere (`ident()` for interpolated names), no `console.*` or
`process.env` in `src/`, goals only inside `<user_context>`, numbers only from Figures. The new leak guard is a
superset of the old `assertDerivedOnly` (email, scheme URL, plus host-with-path). Round-1 fixes 1, 2, 3, 4, 7 and 9 are
real and tested (R1 to R6); 5 is docs only, 6 is process, 8 is deferred with a reason, 10 adds coverage (M-B shows it
bites). Findings 1 to 3 below are gaps left by round-1 fixes or missed in round 1.

### Findings

1. **MINOR. A model sentence with a bare link is still stored.** Round-1 fix 1 uses `hasLeak`
   (`narrative.ts:80`), which allows bare hosts (`names.ts:52-55`). Probe at `39af2e3`: `"A steady week of 12 h. Visit
   www.evil.example for tips."` and `"A steady week of 12 h; see evil.example."` come back `source: "model"`, and
   `setWeekNarrative`'s guard lets them through, so the link reaches the member's weekly review. Task names are model
   input, so prompt injection could plant it. The new NARRATIVE test covers only `www.` with a path. *Fix:* use
   `hasLink` in `writeWeekSentence` and in `writeWeekNarrative`'s second-transaction recheck (`job.ts:104`). Add the
   two probe sentences to the NARRATIVE test, red first.
2. **MINOR. `hasLink` is narrower than API.md says.** API.md: "may not hold a link, including a bare `www.` or host
   name (`acme.com`)". `HOST_TOKEN_RE` only knows 23 suffixes (`names.ts:42-43`). Probe: goals `"Grow signups on
   bit.ly"`, `"Founder at acme.ca"`, `"Hit 10k on example.in"` and `"Sell on shop.example"` are accepted (200), and go
   to the model inside `<user_context>`. *Fix:* refuse any dotted token whose last label is 2 or more letters, except
   a short list of code suffixes (`js`, `ts`, `py`, `md`, …). Or say "a host name with a common web suffix" in API.md.
   Add the probe cases to PROFILE either way.
3. **MINOR. The request body is read inside the tenant transaction.** `handleUserModelRequest` opens `runInTenant`
   (`handlers.ts:169`), and `readJson` runs inside it (`handlers.ts:115`, `152`). Probe with a recording `RunInTenant`:
   `tx begin | body chunk read, tx open=true | tx end`. With `bunRunInTenant`, a slow client holds a pooled
   connection and an open transaction (after `SET LOCAL`) for as long as it trickles up to 64 KiB. ADR 0013 (line 45)
   and DATA_MODEL 1 forbid network I/O inside `withTenant`; this is client I/O, not a model call, but it has the same
   pool cost. *Fix:* route, then read and parse the body, then call `runInTenant`. Test with a fake `RunInTenant`
   that asserts the body stream is fully consumed (or refused) before it is called.
4. **NIT. The declared `Content-Length` cap is untested.** M-D passes. The stream cap still returns 413, so behaviour
   holds, but the early refusal is unpinned. Add a request with `content-length: 70000` and a short body to the API
   413 test.
5. **NIT. A timezone mismatch can make a durable step retry forever.** `TimezoneMismatchError` (`job.ts:16-18`) is
   thrown for a window built before a timezone change. The same window will fail on every retry. Note under DESIGN
   section 4 (W1-C / m5-05) that `timezone_mismatch` is not retryable and the window must be rebuilt.
6. **NIT (carried).** Round-1 finding 8 (glossary: `never` vs `left_alone`, missing "Focus block", "Time share",
   "Revision group", "Track record") is still open. It is out of `paths_in_scope`; it needs a docs slice that owns
   `docs/GLOSSARY.md`.

No BLOCKER or MAJOR finding. Findings 1 to 3 should be fixed in a follow-up round on this branch, red test first.

VERDICT: PASS

### Author response (round 2)

Author: Claude Code (Opus 5.5), the author of both slices. Every behaviour change had its test committed and seen
failing before the fix. Red commits `b95c828` (p43a) and `64c7d7c` (p43b); fixes `7842be1` (p43a) and `936ee9d`
(p43b); docs `be23ccf`. After the round: `p43a-user-model-core: PASS` (63 tests; two existing tests gained cases),
`p43b-user-model-store-api: PASS` (31 tests, was 30), full suite 144 pass, `verify-all: green`, 0 leftover test
schemas or roles. Scope is unchanged; no test assertion was weakened.

1. **Fixed.** `writeWeekSentence` now uses `hasLink`, so a bare host in a model sentence falls back to the code
   sentence. As a second line, `writeWeekNarrative`'s second-transaction recheck and `setWeekNarrative` also refuse
   `hasLink` text. Your two probe sentences (`Visit www.evil.example for tips.`, `see evil.example.`) were added to
   the NARRATIVE link test; both failed at `b95c828` and pass at `7842be1`.
2. **Fixed (widened the check to match API.md, not the other way round).** `hasLink` now refuses `www.` and any
   dotted token whose last label has 2 or more letters, unless that label is a code or file suffix (`md`, `js`, `ts`,
   `py`, `json`, `pdf`, …). The PROFILE validation test gained `bit.ly`, `acme.ca`, `example.in` and `shop.example`
   (all failed at `b95c828`), and its accepted case now pins `Update README.md for v2.0` and `Learn Node.js`. Known
   edge: a host on one of those suffixes (`acme.md`) and a few names like `ASP.NET` are judged by suffix; API.md says
   "any host name; code file names are allowed".
3. **Fixed.** `handleUserModelRequest` reads (or refuses, with 400 or 413) the body before it calls `runInTenant`;
   `handle` receives the parsed body, not the `Request`. New test `API: the request body is read before the tenant
   transaction opens` uses a spy `RunInTenant`: the body stream is consumed when the transaction opens, and an
   oversized or non-JSON body opens no transaction. Red at `64c7d7c` (`opened` was `[false]`).
4. **Pinned.** The API 413 test now also sends `content-length: 70000` with a 2-byte valid JSON body: 413, and the
   stream is never pulled. It passed on first run (the behaviour existed); dropping the declared check makes it
   fail (checked, then restored). The test streams use `highWaterMark: 0`, so a pull means a real read, not a
   prefetch.
5. **Fixed.** `TimezoneMismatchError` carries `retryable = false` next to `code = "timezone_mismatch"`. The STORE
   timezone test asserts both (red at `64c7d7c`). DESIGN section 4 tells the durable step (W1-C, m5-05) not to
   retry and to rebuild the window in the profile's timezone.
6. **Still deferred (scope).** `docs/GLOSSARY.md` is outside both slices' `paths_in_scope`, and these rounds keep
   scope unchanged. The proposed wording in the round 1 response stands for a docs slice that owns the glossary.

## Round 3

Independent reviewer (Claude Code, Opus 5.5). It did not write this code. Reviewed at `4305e6e`. Read: AGENTS.md (review
gate), CLAUDE.md, both SPECs, DESIGN.md, ADR 0003, 0013 and 0019, DATA_MODEL 1 and 4, API.md (profile, records,
review), ARCHITECTURE 5 and 6, SECURITY_PRIVACY 13, MIGRATION 5.4, ONBOARDING 11.12, `git diff 8f6ff2d..HEAD`
(54 files), every test file, and each round-2 commit (`b95c828`, `7842be1`, `64c7d7c`, `936ee9d`, `be23ccf`). Old code
at `/workspace/offload-wsB` (`f9e2793`, read only) checked for `checkNarrative` (`brain/src/memory/week-record.ts:309`)
and for any learning-pause handling (there is none in `brain/src/usermodel` or `memory`).

### Runs (DATABASE_URL set, local Postgres 17)

| Command | Result |
|---|---|
| `bash scripts/verify-all.sh` | `verify-all: green`. Full suite **144 pass, 0 fail**, 34 files, 2637 `expect()` calls. Both done slices PASS; slices lint ok (10 specs), doc links ok (70 files), copy ok, secrets ok, workflows ok, license boundary ok. |
| `bash slices/p43a-user-model-core/verify.sh` | `p43a-user-model-core: PASS`. Slice suite **63 pass, 0 fail**, 7 files (`min_tests` 55). LEDGER 7, OBSERVE 2, DAY 6, LEAKS 2, WEEK 4, THEIL-SEN 2, MONTH 2, QUARTER 1, NARRATIVE 5, SCORE 8, PROPOSE 5, LONG-TERM 2, INVALIDATE 2, SUPERSEDE 2, REVISE 1, MERGE 1, PROFILE 5, PROMPTS 2, PRIVACY 1, REVIEW 3. Full suite 144/144. Scope checked (54 files). |
| `bash slices/p43b-user-model-store-api/verify.sh` | `p43b-user-model-store-api: PASS`. Slice suite **31 pass, 0 fail**, 4 files (`min_tests` 20). PROFILE 5, API 12, PRIVACY 1, RLS 5, MERGE 1, INVALIDATE 2, STORE 5. Full suite 144/144. Scope checked (31 files). |

No `skip`, `todo` or `.only`. The Postgres files use `describe.skipIf(!HAS_DB)`, and p43b's `verify.sh` has
`NEEDS_POSTGRES=1`. After every run, mutation runs included: 0 leftover `p43b%` schemas and 0 `p43b%` roles.
`git status` was clean after the last mutation.

### 1. Tests fail without the code (mutation check)

Each change was made alone with a scripted edit, the covering test files were run, and the file was restored with
`git checkout -- <file>`.

| # | Change (file:line) | Result |
|---|---|---|
| S1 | `writeWeekSentence` without `hasLink` (`src/records/narrative.ts:80`) | NARRATIVE link test fails (round-2 fix 1 is real) |
| S2 | `hasLink` ignores host tokens (`src/user-model/names.ts:54`) | NARRATIVE link and PROFILE validation fail (fix 2) |
| S3 | `hasLink` refuses every dotted token (no code suffixes) | PROFILE validation fails (the accepted `README.md` / `Node.js` edge is pinned) |
| S4 | Body read back inside `runInTenant` (`src/http/handlers.ts:169-170`) | API "body is read before the tenant transaction opens" fails (fix 3) |
| S5 | Declared `Content-Length` check removed (`handlers.ts:47`) | API 413 test fails (round-2 NIT 4 is now pinned) |
| S6 | `retryable = true` (`src/store/job.ts:20`) | STORE timezone test fails (fix 5) |
| S7 | `writeWeekNarrative` recheck without `hasLink` (`job.ts:107`), alone and together with S8 | **no test fails** (finding 3) |
| S8 | `setWeekNarrative` without the `hasLink` refusal (`src/store/repository.ts:209`) | **no test fails** (finding 3) |
| S9 | Future-week 404 removed from `GET /v1/records/weeks` (`handlers.ts:130`) | **no test fails** (finding 2) |
| S10 | Future-week 404 removed from `GET /v1/review/week` (`handlers.ts:144`), alone and with S9 | **no test fails** (finding 2) |
| S11 | `subject_key` pattern check removed (`src/review/answers.ts:41`) | REVIEW and API bad-answer tests fail |
| S12 | Future-week answer accepted (`answers.ts:48`) | REVIEW and API bad-answer tests fail |
| S13 | Unknown goal in an answer accepted (`answers.ts:49`) | REVIEW and API bad-answer tests fail |
| S14 | `member_isolation` passes for any `app.member_scope` value (`sql/0001_user_model.sql:236`) | 3 RLS tests fail |
| S15 | `FORCE ROW LEVEL SECURITY` dropped (`sql:230`) | RLS catalog test fails |
| S16 | Repository `guard()` a no-op (`repository.ts:39`) | STORE leak test fails |
| S17 | `<user_context>` keeps `<` and `>` (`src/understanding/context.ts:15`) | PROMPTS fails |
| S18 | `tenant_isolation` without `WITH CHECK` (`sql:233`) | passes, as expected: Postgres uses `USING` as the check (equivalent mutation) |
| S19 | UUID check removed (`src/store/tenant.ts:37`); profile lock removed (`handlers.ts:115`); state filter removed (`repository.ts:323`); `>` to `>=` at the 50% contradiction edge (`src/user-model/merge.ts:26`) | **no test fails** (finding 5) |

### 2. Test changes after the red commits

Test files changed only in the red commits `8c22dc8`, `adff86b`, `935f14e` (green, see round 1), `c69e88e`, `fd2454f`,
`3a2edd6`, `b95c828` and `64c7d7c`. None changed after `64c7d7c`. Lines removed in round 2:
- `profile.test.ts:95`: the accepted case changed its goal `"b"` to `"Update README.md for v2.0"`. Nothing that was
  refused is now accepted. The new goal pins the false-positive edge, so this is not a weakening. A one-character
  goal is no longer pinned as accepted, which is harmless.
- `api.test.ts`: an unused type import was widened.
- `store.test.ts`: `rejects.toThrow(/timezone/)` became `String(err)` matching `/timezone/` plus
  `toMatchObject({ code, retryable: false })`. A resolved promise gives `"null"`, which fails, so this is equivalent
  and stricter.

**No assertion was weakened.** The mandatory list of MIGRATION 5.4 is present by name (listed in round 1). One
clause is vacuous: "future week 404" in `API: GET /v1/review/week?w= …` and in the records-weeks test (finding 2).

### 3. Correctness

Round-2 changes match the docs: the body is read before `runInTenant` (ADR 0013, line 45), `timezone_mismatch` is
non-retryable (DESIGN section 4), and the API.md wording for links matches the code except for finding 4. Tables,
columns, keys, RLS policy text, status codes and the Figure shape are unchanged since round 2. They still match
DATA_MODEL 4, ADR 0013 and API.md's closed error list. Bi-temporal rules are unchanged (`merge.ts:64,76`; `CHECK
(invalid_at >= valid_at)`; one current version per key).

### 4. Security and privacy

Re-checked at `4305e6e`:
- RLS runs as a `NOBYPASSRLS` non-owner role, with member and tenant walls on all 12 tables (S14, S15).
- Every value is a bind parameter, and interpolated names pass `ident()`.
- There is no `console.*`, `process.env` or `fetch(` in `src/`.
- Goals reach a model only inside `<user_context>` (S17).
- Review answers are pattern-checked, so no free text reaches `review_answers` (S11).
- Observation ids appear only as evidence.

Round-2 fixes 1 to 5 are real, and S1 to S6 show the tests catch them. Two gaps remain: the new storage-side link
check (finding 3) and the code-suffix exception (finding 4). Finding 1 breaks ADR 0003 in user-visible text. It was
carried over from the old `checkNarrative` (`f9e2793`, `brain/src/memory/week-record.ts:309`, digits only), and
rounds 1 and 2 missed it.

### 5. Scope

All 54 changed files match `paths_in_scope`. There is nothing under `packages/`, `services/api`, `services/runtime`,
`services/broker`, `services/builder`, `apps/`, `ee/`, `.github/` or `docs/adr/`. `bun.lock` and `package.json` are
unchanged since `8f6ff2d`. NOTICE moves gum (MIT) and graphiti (Apache-2.0) from "Planned" to "included", naming the
files that use their ideas.

### Findings

1. **MAJOR. A number written as a word passes the narrative check, so a model can show an invented number (ADR
   0003).**
   - *Cause:* `checkNarrative` only matches digits (`NUMBER_RE = /\d+(?:\.\d+)?/g`, `src/records/narrative.ts:12`).
   - *Probe at `4305e6e`:* the record's total is 12 h. `writeWeekSentence(rec, undefined, async () => "You spent forty
     hours this week, twice the usual.")` returns `source: "model"`.
   - *Effect:* `writeWeekNarrative` rechecks with the same function and stores the sentence (`src/store/job.ts:107-108`).
     `GET /v1/review/week` then shows it (`src/review/week-review.ts:43`).
   - *Likelihood:* the prompt asks for "plain words" (`narrative.ts:50`), which invites spelled-out numbers. Task names
     are model input, so prompt injection can also steer it.
   - *Docs broken:* ADR 0003 ("any model text that contains a number is checked … a number not present in the record
     … is refused"), AGENTS ground rules ("A model never produces a number a user sees"), and the SPEC NARRATIVE row.

   *Fix:* make `checkNarrative` treat English number words as numbers: cardinals `zero` … `nineteen`, the tens,
   `hundred`, `thousand`, `million`, `dozen`; and multiples and fractions such as `half`, `twice`, `double`, `triple`,
   `thrice`. Either map them to values and check them against `known`, or refuse any sentence that holds one (a
   refusal only costs the code sentence). Add NARRATIVE cases red first: `forty hours` against a 12 h record is
   refused, `twice the usual` is refused, and a sentence without numbers still passes.
2. **MINOR. The future-week 404 guards are untested; the mandatory test's "future week 404" clause passes
   vacuously.**
   - *Evidence:* `api.test.ts:47` and `:82` ask for `2026-W47`, which has no stored record, so the 404 comes from "no
     record". Removing both guards (`handlers.ts:130`, `:144`; S9, S10) leaves 31/31 passing.

   *Fix:* call a stored week (`W`) with `now` set before its Monday in the profile's timezone, and expect 404
   `not_found` on both routes. Confirm it is red with the guard removed.
3. **MINOR. Round-2 fix 1's storage-side check is untested.** The round-2 response says `setWeekNarrative` and
   `writeWeekNarrative`'s recheck "also refuse `hasLink` text" (`repository.ts:209`, `job.ts:107`). Removing both
   (S7, S8) leaves 31/31 passing. The recheck in `job.ts` cannot be reached today, because `writeWeekSentence`
   refuses first. `setWeekNarrative` is an exported repository function and the last line before a member-visible
   column.

   *Fix:* add a STORE test: `setWeekNarrative(tx, W, "A steady week; see evil.example.")` throws `LeakError`, and
   `week_records.narrative` is unchanged.
4. **MINOR. Code suffixes that are real top-level domains let host names through.**
   - *Cause:* `CODE_SUFFIXES` (`src/user-model/names.ts:43`) holds `sh`, `rs`, `md` and `py`, which are delegated
     ccTLDs used by real sites.
   - *Probes:* goals `"Grow signups on bun.sh"`, `"Ship docs.rs page"` and `"Promote evil.md"` are accepted. The
     model sentence `"A steady week of 12 h; try evil.sh for tips."` returns `source: "model"` and would be stored,
     because `setWeekNarrative` uses the same `hasLink`.
   - *Docs:* API.md (lines 183-184) now says "any host name". The round-2 response names `acme.md` as a known edge,
     but neither API.md nor the sentence path accounts for it. The sentence path is the injection route of round-2
     finding 1.

   *Fix:* use a strict variant with no suffix exception for model text (`writeWeekSentence`, the job recheck and
   `setWeekNarrative`). For profile text, either drop `sh`, `rs`, `md` and `py` from the exception, or name the
   exception in API.md. Add the probe cases red first.
5. **NIT. Guards no test pins (S19):**
   - the uuid check in `bunRunInTenant` (`tenant.ts:37`); Postgres would fail the `::uuid` cast anyway, as a 500;
   - the profile advisory lock (`handlers.ts:115`);
   - the state filter in `applyAnswerToOpportunity` (`repository.ts:323`); without it, a `never` answer would move a
     `chosen` or `building` opportunity back to `never`;
   - the exact 50% contradiction edge (`merge.ts:26`; the SPEC says "over 50%").

   A test for the state filter is worth adding. The others are optional.
6. **NIT. Other link shapes in profile text.** `"Grow signups on 203.0.113.9"` (an IP address) and full-width or
   ideographic dots (`evil．com`, `evil。com`) are accepted. API.md says "no … link". The risk is low. Either refuse
   them or narrow the API.md wording.
7. **NIT. `learning_paused` is not checked by the job.** ONBOARDING 11.12 says records are not updated while learning
   is paused. Uploads stop on the Mac, so only a window ingested before the pause is affected, and the old code had
   no check either. *Fix:* skip in `runMemberUpdate` when `profile.learning_paused`, or tell the m5-05 durable step to
   check it (DESIGN section 4).
8. **NIT (carried).** Round-1 finding 8 (glossary: `never` vs `left_alone`; "Focus block", "Time share", "Revision
   group" and "Track record" are missing) is still open. It is outside `paths_in_scope`.

Finding 1 is MAJOR and blocks PASS. Fix it red test first, and fix findings 2 to 4 in the same round.

VERDICT: CHANGES

### Author response (round 3)

Author: Claude Code (Opus 5.5), the author of both slices. Every behaviour change had its test committed and seen
failing before the fix; each pin test was checked against the mutation you used. Red commits `cb5d715` (p43a) and
`6b0547f` (p43b); fixes `6986b8d` (p43a) and `7508c33` (p43b); docs `5d8064f`. After the round:
`p43a-user-model-core: PASS` (65 tests, was 63), `p43b-user-model-store-api: PASS` (35 tests, was 31), full suite
150 pass, `verify-all: green` (copy lint ok), 0 leftover test schemas or roles. Scope is unchanged; no assertion was
weakened (test files only gained tests and list entries).

1. **Fixed (MAJOR).** `checkNarrative` now reads cardinal number words as numbers: `zero` … `nineteen`, the tens, and
   `forty-two` / `forty two` compounds, each checked against the record's known values like a digit (case-insensitive).
   Multipliers, fractions and scales (`half`, `twice`, `thrice`, `double(d)`, `triple(d)`, `quadruple(d)`, `dozen`,
   `quarter`, `third`, `hundred`, `thousand`, `million`, `billion`, plural forms) are always refused. The prompt now
   says "Write every number in digits, never as a word, and do not compare with other weeks". New test `NARRATIVE:
   numbers written as words are checked like digits; multipliers and fractions are refused`: `three` and `Twelve`
   pass against a 3-block, 12 h record; a sentence with no number passes; `forty hours … twice the usual` is refused
   with `forty` and `twice` in `unknown`; `four`, `twenty-one`, `twenty one`, `Half`, `doubled`, `dozen`, `hundred`,
   `third` are refused; `writeWeekSentence` falls back to the code sentence for your probe. Red at `cb5d715`. Ordinals
   other than `third` (`first`, `second`) are not read; DESIGN section 7 says so.
2. **Fixed (test).** New test `API: a stored week after the member's current week is 404 on both routes`: `2026-W45`
   is stored and answers 200 at the seeded `now`, and 404 `not_found` on both `GET /v1/records/weeks/2026-W45` and
   `GET /v1/review/week?w=2026-W45` at Tuesday of `2026-W43`. It passes against the code; with both guards removed
   (your S9 and S10) it fails (checked, then restored).
3. **Fixed (test).** New test `STORE: setWeekNarrative refuses any link, including host names on code-like suffixes;
   the stored sentence is unchanged` (`evil.example`, `evil.sh`, an IP address; each throws `LeakError`, and the
   stored narrative is unchanged). Red at `6b0547f` for `evil.sh` and the IP address (finding 4). The recheck in
   `writeWeekNarrative` is still not reachable through the public path, because `writeWeekSentence` refuses first; it
   uses the same strict check and stays as a second line.
4. **Fixed.** Two checks now: `hasAnyLink` (no exception) guards everything a model writes (`writeWeekSentence`, the
   job recheck and `setWeekNarrative`); `hasLink` keeps the code-file exception for text a person types. Your model
   probe `try evil.sh for tips` and `read docs.rs today` fall back to the code sentence (NARRATIVE link test, red at
   `cb5d715`). For profile text I kept the exception and named it in API.md (a host on `md`, `js`, `py`, `sh`, `rs`
   and the like, for example `bun.sh`, is accepted), because dropping `md`/`sh`/`rs`/`py` would refuse
   `README.md`-style goals; the text is the member's own and reaches a model only inside `<user_context>`.
5. **Partly done (NIT).** Pinned the two you called worth it: `STORE: a review answer never moves an opportunity that
   has left the review states` (a `chosen` opportunity stays `chosen` after `never`; fails without the state filter)
   and `SUPERSEDE: a rate change of exactly 50% revises; just over 50% starts a new version` (fails with `>=`). Not
   pinned: the uuid check in `bunRunInTenant` (ids come only from verified tokens, and without it Postgres refuses the
   cast with no data shown) and the profile advisory lock (a reliable test needs two interleaved transactions and
   timing; left as reviewed code).
6. **Fixed (NIT).** Both link checks read full-width and ideographic dots (`．`, `。`, `｡`) as dots and refuse IPv4
   addresses. PROFILE validation gained `203.0.113.9`, `evil．com` and `evil。com` (red at `cb5d715`).
7. **Fixed (NIT).** `runMemberUpdate` returns `paused: true` and writes nothing while `profiles.learning_paused` is
   true (checked before the timezone rule). New test `STORE: the job changes nothing while learning is paused` (no
   rows in any of six tables). Red at `6b0547f`. DESIGN section 4 says so.
8. **Still deferred (scope).** `docs/GLOSSARY.md` is outside both slices' `paths_in_scope`; the proposed wording in the
   round 1 response stands for a docs slice that owns it.

## Round 4

Independent reviewer (Claude Code, Opus 5.5). It did not write this code. Reviewed at `131a1c2`. Read: AGENTS.md (review
gate, slice format, privacy rules), CLAUDE.md, both SPECs, DESIGN.md, ADR 0003, 0013 and 0019, DATA_MODEL 1 and 4,
API.md (conventions, error envelope, Figure, profile, records, review), ARCHITECTURE 5 and 6, SECURITY_PRIVACY 13,
MIGRATION 5.4, `git diff 8f6ff2d..HEAD` (54 files), every file in `services/brain/src` and `services/brain/sql`, every
test file, and each round-3 commit (`cb5d715`, `6986b8d`, `6b0547f`, `7508c33`, `5d8064f`). Old code at
`/workspace/offload-wsB` (`f9e2793`, read only): `api/memory-routes.ts`, `profile/store.ts` validation,
`memory/week-record.ts` `checkNarrative`. No old rule is lost: the old profile checks are all present or stricter, and
old `exclusions` moved to their own M3 table.

### Runs (DATABASE_URL set, local Postgres 17)

| Command | Result |
|---|---|
| `bash scripts/verify-all.sh` | `verify-all: green`. Full suite **150 pass, 0 fail**, 34 files. Typecheck ok, license boundary ok, both done slices PASS, slices lint ok (10 specs), doc links ok (70 files), copy ok, secrets ok, workflows ok. |
| `bash slices/p43a-user-model-core/verify.sh` | `p43a-user-model-core: PASS`. Slice suite **65 pass, 0 fail**, 7 files (`min_tests` 55). LEDGER 7, OBSERVE 2, DAY 6, LEAKS 2, WEEK 4, THEIL-SEN 2, MONTH 2, QUARTER 1, NARRATIVE 6, SCORE 8, PROPOSE 5, LONG-TERM 2, INVALIDATE 2, SUPERSEDE 3, REVISE 1, MERGE 1, PROFILE 5, PROMPTS 2, PRIVACY 1, REVIEW 3. Full suite 150/150. Scope checked (54 files). |
| `bash slices/p43b-user-model-store-api/verify.sh` | `p43b-user-model-store-api: PASS`. Slice suite **35 pass, 0 fail**, 4 files (`min_tests` 20). PROFILE 5, API 13, PRIVACY 1, RLS 5, MERGE 1, INVALIDATE 2, STORE 8. Full suite 150/150. Scope checked (32 files). |

There are no `skip`, `todo` or `.only` tests. The Postgres files use `describe.skipIf(!HAS_DB)`, and p43b's `verify.sh`
has `NEEDS_POSTGRES=1`, so a missing database fails instead of passing vacuously. After every run, the mutation runs
and the probes included, there were 0 leftover `p43b%` schemas and 0 `p43b%` roles. `git status` was clean before this
file was written.

### 1. Tests fail without the code (mutation check)

Each change was made alone with a scripted `perl` edit. Then `bun test services/brain` ran (100 tests) and the file
was restored with `git checkout -- <file>`.

| # | Change (file:line) | Result |
|---|---|---|
| T1 | `numberWords` returns `[]` (`src/records/narrative.ts:27`) | NARRATIVE number-words test fails (round-3 fix 1 is real) |
| T2 | `setWeekNarrative` without `hasAnyLink` (`src/store/repository.ts:209`) | STORE `setWeekNarrative` test fails (fix 3) |
| T3 | `learning_paused` check removed (`src/store/job.ts:47`) | STORE paused test fails (NIT 7) |
| T4 | `member_isolation` is `OR true` (`sql/0001_user_model.sql:236`) | 3 RLS tests fail |
| T5 | `>` to `>=` at the 50% edge (`src/user-model/merge.ts:26`) | SUPERSEDE edge test fails (NIT 5) |
| T6 | IPv4 check removed from `linkIn` (`src/user-model/names.ts:55`) | PROFILE validation and STORE `setWeekNarrative` fail (NIT 6) |
| T9 | Stale rule `<` to `<=` (`merge.ts:75`) | INVALIDATE gap test fails |
| T11 | `isDay` check removed from `GET /v1/records/days` (`src/http/handlers.ts:123`) | API days test fails |
| T14 | `bunRunInTenant` always sets `app.member_scope = 'tenant'` (`src/store/tenant.ts:43`) | 3 RLS tests fail |
| T15 | Closed days `<` to `<=` today (`src/records/day-record.ts:63`) | 2 DAY tests fail |
| T17 | `NOT_NOW_WEEKS` 4 to 5 (`src/opportunities/score.ts:17`) | SCORE `not_now` test fails |
| T18 | `applyAnswerToOpportunity` not called (`handlers.ts:155`) | API answers test fails |
| T19 | Wide dots no longer read as dots (`names.ts:54`) | PROFILE validation fails |
| T7 | A stored sentence always survives a rebuild (`job.ts:67`, the `checkNarrative` recheck removed) | **no test fails** (finding 3) |
| T8 | A job rerun resets the opportunity `state` to `open` (`repository.ts:301`) | **no test fails** (finding 4) |
| T10 | `goal_id` accepted with any answer (`src/review/answers.ts:47`) | **no test fails** (finding 4) |
| T12 | Extra keys in a `{ text }` goal accepted (`src/profile/profile.ts:111`) | **no test fails** (finding 4) |
| T16 | Questions no longer skip score-0 opportunities (`src/review/week-review.ts:47`) | **no test fails** (finding 4) |
| T20 | Control-character check removed from profile text (`profile.ts:70`) | **no test fails** (finding 4) |

### 2. Test changes after the red commits

Test files changed only in the red commits `8c22dc8`, `adff86b`, `c69e88e`, `fd2454f`, `3a2edd6`, `b95c828`, `64c7d7c`,
`cb5d715` and `6b0547f`, plus `935f14e` (green, covered in round 1). No fix or docs commit touched a test. The only
line removed in round 3 is an import in `store.test.ts` (`6b0547f`), widened to more names. The round-3 tests assert
real behaviour:
- the 50% edge is pinned both ways;
- the stored narrative is unchanged after each refused write;
- the paused job leaves zero rows in six tables;
- a `chosen` opportunity stays `chosen`;
- the future-week test calls a stored week, so it no longer passes vacuously (round-3 finding 2 is closed).

**No assertion was weakened.** Every mandatory red test in MIGRATION 5.4 is present by tag and name, as rounds 1 to 3
found. Nothing was removed since.

### 3. Correctness

The tables, columns, keys, policy text and grants match DATA_MODEL 4, plus the additions it records. RLS matches ADR
0013, and the error codes are in API.md's closed list. The Figure shape and `fig_` id match API.md. The bi-temporal
rules hold: `invalid_at = max(old valid_at, new valid_at)`, `CHECK (invalid_at >= valid_at)`, one current version per
key, and no DELETE grant on propositions. The score, `paybackWeeks`, the drain boost, `declinePenalty` and `not_now` for
4 weeks match ARCHITECTURE 6. Persistence, Theil-Sen over week index, the 8-calendar-week baseline and focus blocks
(gaps under 2 min) match ARCHITECTURE 5. The round-3 fixes match the docs; T1 to T6 show each is tested. The one
correctness gap is ADR 0003 (finding 1).

### 4. Security and privacy

- **RLS:** tests run as a `NOLOGIN NOBYPASSRLS` role that does not own the tables. The member and tenant walls hold on
  all 12 tables, and the tenant and member come only from `auth` (T4, T14).
- **SQL:** every value is a bind parameter. Interpolated text is a constant (`TID`, `MID`, `OWN`, `ROLLUP_TABLE`, the
  column lists) or passes `ident()`.
- **No I/O or logs:** `src/` has no `console.*`, `process.env` or `fetch(`. The request body is read before
  `runInTenant`, and the model call is outside both transactions.
- **Goals:** they reach a prompt only inside `<user_context>`.
- **Raw text:** the PRIVACY test dumps every table as the superuser and finds no title, text, URL or email.
- **Two gaps:** non-ASCII digits get past the narrative check (finding 1) and past the name scrubber (finding 2).

### 5. Scope

All 54 changed files are in `paths_in_scope`. Nothing changed under `packages/`, `services/api`, `services/runtime`,
`services/broker`, `services/builder`, `apps/`, `ee/`, `.github/` or `docs/adr/`. `package.json` and `bun.lock` are
unchanged since `8f6ff2d`, and there is no new dependency. NOTICE lists gum (MIT) and graphiti (Apache-2.0) as ideas
only, naming the files that use them.

### Findings

1. **MAJOR. A number written in non-ASCII digits or as a number character passes the narrative check, so a model can
   show an invented number (ADR 0003).**
   - *Cause:* `NUMBER_RE = /\d+(?:\.\d+)?/g` (`src/records/narrative.ts:12`) has no `u` flag, so `\d` matches only
     ASCII `0`-`9`. `numberWords` only reads `[a-z]+` tokens (`narrative.ts:29`). Full-width digits (`４０`),
     Arabic-Indic digits (`٤٠`), vulgar fractions (`½`, `¾`) and superscripts (`²`) are not seen at all.
   - *Probe at `131a1c2`:* against a 3-block, 12 h record, `checkNarrative` returns `ok: true` for each of `"You spent
     ４０ hours this week."`, `"You spent ٤٠ hours this week."`, `"You spent ½ your time in meetings."` and `"You hit
     12² emails."`.
   - *End to end (Postgres, own schema, dropped after):* after `seedFourWeeks`, `writeWeekNarrative(run, A1,
     "2026-W45", async () => "You spent ４０ hours at the desk, ½ of it in meetings.")` returns `"model"`.
     `GET /v1/review/week?w=2026-W45` then answers 200 with that sentence, next to a total tile of 14.55 h. The job's
     second-transaction recheck (`src/store/job.ts:111`) and `setWeekNarrative` use the same functions, so neither
     stops it.
   - *Likelihood:* `½` is ordinary model prose. Task names are model input (`narrative.ts:77`), and `safeName` keeps
     non-ASCII digits (finding 2), so a planted title can also steer the model to them.
   - *Docs broken:* ADR 0003 ("any model text that contains a number is checked … a number not present in the record
     … is refused"), AGENTS ground rules, and the SPEC NARRATIVE row. This is the same class as round-3 finding 1.

   *Fix:* in `checkNarrative`, normalize the text with NFKC first (`４０` becomes `40` and is then checked like any
   digit), then refuse any sentence that still holds a number character other than ASCII `0`-`9` (`/[^\P{N}0-9]/u`
   catches `٤`, `½`, `²` and `①`). Add NARRATIVE cases red first: each probe above is refused, and `writeWeekSentence`
   falls back to the code sentence for the end-to-end probe sentence.
2. **MINOR. `safeName` keeps non-ASCII digits in stored names.**
   - *Cause:* `.replace(/[0-9]/g, " ")` (`src/user-model/names.ts:22`). The doc comment (`names.ts:13`) and the LEAKS
     row say "no … digit".
   - *Probe:* `safeName("Ｑ４ report for ٣ clients ①")` returns it unchanged.
   - *Effect:* such names are stored in `task_ledger`, `episodes`, day and week records and propositions. They also
     reach the model prompt, which is the route for finding 1. Masking upstream may normalise them, but this is the
     second line.

   *Fix:* NFKC, then strip `\p{N}` (`/\p{N}/gu`). Add a LEAKS case with full-width and Arabic-Indic digits, red first.
3. **MINOR. The recheck that keeps a stored sentence across a rebuild is untested.** `job.ts:67` keeps the old
   `narrative` only while `checkNarrative` still passes against the rebuilt record. This is an ADR 0003 guard: without
   it, a sentence quoting last run's total survives a rebuild that changed the total. Removing the check (T7) leaves
   100/100 passing.

   *Fix:* add a STORE or MERGE test. Store a model sentence that quotes the week's total, rerun the job with a window
   that changes that total, and expect `narrative` to be null (so the code sentence is served). Confirm it fails
   under T7.
4. **NIT. Guards no test pins (T8, T10, T12, T16, T20).**
   - T8, `repository.ts:301`: a job rerun keeps the opportunity `state`. If it is lost, a rerun of the latest week moves
     a `chosen` or `building` opportunity back to `open`. *Worth a test.*
   - T16, `week-review.ts:47`: questions skip score-0 opportunities. Without it, a task declined with `never` in an
     earlier week is asked about again in every later week. *Worth a test.*
   - T10, `answers.ts:47`: `goal_id` only goes with `keep`, `build` or `other_goal` (API.md).
   - T12, `profile.ts:111`: a `{ text }` goal with extra keys is refused.
   - T20, `profile.ts:70`: control characters are refused. Only `\r` and `\n` are pinned; a tab is not.
5. **NIT. C1 control and format characters get into profile text.** `line()` (`profile.ts:70`) and the
   `<user_context>` cleaner (`src/understanding/context.ts:15`) drop only C0 controls and DEL. Probe:
   `applyProfilePatch(defaultProfile(), { goals: ["Grow\u0085signups"] })` is accepted with the NEL kept (a line
   break to some renderers). A zero-width space (`"Ship​v2"`) is accepted too. API.md says "one line".

   *Fix:* use `/[\p{Cc}\p{Cf}]/u` in both places and add the NEL case to the PROFILE validation test.
6. **NIT (carried).** Round-1 finding 8 is still open. The glossary still disagrees on `never` vs `left_alone`, and
   "Focus block", "Time share", "Revision group" and "Track record" have no entry. It is outside `paths_in_scope`.

Finding 1 is MAJOR and blocks PASS. Fix it red test first. Fix findings 2 and 3 in the same round; for finding 4, at
least T8 and T16 should get tests.

VERDICT: CHANGES

### Author response (round 4)

Author: Claude Code (Opus 5.5), the author of both slices. Every behaviour change had its test committed and seen
failing before the fix; every pin test was checked against the mutation you used (each a one-line change, then
restored). Red commit `6da626b` (p43a), fix `8219ebf` (p43a), p43b tests `d66885b`, docs `ed99313`. After the round:
`p43a-user-model-core: PASS` (67 tests, was 65), `p43b-user-model-store-api: PASS` (37 tests, was 35), full suite 154
pass, `verify-all: green` (copy lint ok), 0 leftover test schemas or roles. Scope is unchanged; no assertion was
weakened (test files only gained tests and list entries).

1. **Fixed (MAJOR).** `checkNarrative` first collects every number character that is not an ASCII or full-width digit
   (`/[^\P{N}0-9０-９]/u`: `٤`, `½`, `²`, `①`, …) as unknown, so such a sentence is always refused; it then
   reads the text after NFKC, so full-width digits are checked like ASCII ones (`１２` passes against 12 h, `４０`
   does not). New test `NARRATIVE: non-ASCII digits are read after NFKC; other number characters are refused`: all
   four of your probes plus `③` are refused, and `writeWeekSentence` falls back to the code sentence for your
   end-to-end sentence (`４０ hours …, ½ of it in meetings`). Red at `6da626b`. The job recheck and the API read path
   use the same function, so the stored path is closed too.
2. **Fixed.** `safeName` applies NFKC, then strips every `\p{N}` (and replaces `\p{Cc}`, `\p{Cf}`, `\p{Zl}`, `\p{Zp}`
   with spaces). Your probe `Ｑ４ report for ٣ clients ①` becomes `Q report for clients` (LEAKS test, red at
   `6da626b`).
3. **Fixed (test).** New test `STORE: a stored weekly sentence survives a rebuild only while its numbers are still in
   the record`: a sentence quoting the week's total survives a rerun of the same window and becomes null after a
   rerun whose window changes the total (the test asserts the total changed). It passes against the code and fails
   with the recheck removed (your T7).
4. **Done (NIT).** Pinned all five, each failing under your mutation: T8 `STORE: a job rerun keeps an opportunity's
   state` (`building` survives a rerun); T16 `REVIEW: an open opportunity that scores 0 (declined earlier) is not
   asked about`; T10 a `never` answer with a `goal_id` is `schema_invalid` (REVIEW validation list); T12 a `{ text,
   extra }` goal and T20 a tab are refused (PROFILE validation list).
5. **Fixed (NIT).** Profile `line()` treats `\r`, `\n`, NEL, U+2028 and U+2029 as a second line and refuses any
   `\p{Cc}` or `\p{Cf}` (so a zero-width space or a tab is refused); the `<user_context>` cleaner drops `\p{Cc}`,
   `\p{Cf}`, `\p{Zl}` and `\p{Zp}`. PROFILE validation gained NEL, zero-width space and U+2028 cases, and PROMPTS
   checks the cleaner (red at `6da626b`). Side effect named in API.md's rule: emoji joined with a zero-width joiner
   are refused in goals.
6. **Still deferred (scope).** `docs/GLOSSARY.md` is outside both slices' `paths_in_scope`; the round 1 response's
   wording stands for a docs slice that owns it.
