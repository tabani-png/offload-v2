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
