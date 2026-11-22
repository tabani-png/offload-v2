# p43a / p43b design note: port of old PR #43 (s36 user memory) into `services/brain`

Binding plan: [MIGRATION 5.4](../../docs/MIGRATION.md#54-pr-43-featuser-model-gum-graphiti-s36-user-memory). Storage:
[ADR 0019](../../docs/adr/0019-user-model-storage.md), [DATA_MODEL 4](../../docs/DATA_MODEL.md#4-user-model). Old code is
read from `feat/user-model-gum-graphiti` at `f9e2793` (four commits, 55 tests in `brain/tests/s36-user-memory/`).
Slices: `p43a-user-model-core` (pure logic) and `p43b-user-model-store-api` (Postgres, repository, handlers).

## 1. Old file → v2 file

| Old (`brain/src/…`) | Fate | v2 (`services/brain/…`) |
|---|---|---|
| `memory/ledger.ts` | keep + centroid | `src/user-model/ledger.ts` |
| `usermodel/observe.ts` (`safeName`, per-task counts) | rewrite | `src/user-model/observe.ts`, `src/user-model/names.ts` |
| `usermodel/{propose,merge,types}.ts` | keep (fixes below) | `src/user-model/{propose,merge,types}.ts` |
| `usermodel/model.ts`, `memory/update.ts` | rewrite | `src/user-model/update.ts` (pure); `src/store/job.ts` (p43b) |
| `memory/day-record.ts` | rewrite | `src/records/day-record.ts` (episodes inside) |
| `memory/week-record.ts` | split | `src/records/{dates,week-record,rollup,narrative}.ts` |
| `memory/opportunities.ts`, `usermodel/rank.ts` | rewrite | `src/opportunities/score.ts` |
| `memory/answers.ts`, `memory/review.ts` | rewrite | `src/review/{answers,week-review}.ts`; HTTP in `src/http/` (p43b) |
| `profile/store.ts` (validation, goal ids) | rewrite | `src/profile/profile.ts` |
| `understanding/context.ts` (`<user_context>`) | keep (block only) | `src/understanding/context.ts` |
| `time/kinds.ts`, `time/format.ts` | keep | `src/records/kinds.ts` (`format.ts` waits for contracts copy formatting) |
| `api/memory-routes.ts` | rewrite | `src/http/handlers.ts` (p43b) |
| `memory/{seal,cli}.ts`, `usermodel/store.ts`, `usermodel/workflows.ts`, `context/store.ts` | drop | see section 6 |

## 2. Bugs and risks found in the old code, and what v2 does

1. **Host timezone.** `localDay`, `isoWeek`, `weekDaysOf` and "closed day" use the process timezone. In the cloud that
   is UTC, not the member's. v2: days come from `profiles.timezone` through `Intl`; ISO weeks, months and quarters use
   UTC calendar math only.
2. **Proposition confidence used in ranking.** `update.ts` feeds `confidenceScore` into the opportunity score; the
   glossary says it is never used in ranking arithmetic. v2: `confidence = fix-rule confidence × track record`.
3. **`not_now` never expires**, and `leave_alone` is ignored. v2: `not_now` holds for 4 ISO weeks; `never` and
   `leave_alone` hold until a later answer clears them; all three yield to a rise of 50% or more over baseline.
4. **`paybackWeeks` fixed at 1.** v2: `setupHours / weeklyHoursSaved` from the fix estimate.
5. **Staleness on the wall clock.** `merge.ts` ends a belief when `now − lastSeen > 7 days`, so a week with no capture
   (holiday) ends every belief. v2: ended after 7 *analysed* days (days with a day record) after the last sighting.
6. **`invalid_at` before `valid_at`.** A contradiction sets the old version's `invalidAt` to the fresh window's first
   sighting, which can precede the old `validAt` when windows overlap. v2: `max(old.valid_at, fresh.valid_at)`; the
   table has a CHECK.
7. **`checkNarrative` too permissive.** It harvests digit runs from every string, including hex task keys, figure ids
   and hashes, so "9 hours" passes when a key contains a 9. v2: numbers come from numeric values and from
   `arithmetic` and label strings only; id-like strings are skipped; `1,200` is read as 1200.
8. **Theil-Sen over missing weeks.** Rollups drop absent week records and treat the rest as consecutive. v2: slope
   over `(week index, minutes)` points.
9. **Baseline over stored weeks, not calendar weeks.** `listWeeks().slice(-8)` reaches far back across gaps, and
   `weeksObserved` caps at 9. v2: the 8 calendar weeks before the week; `weeks_observed` counts every recorded week.
10. **Empty-name Jaccard = 1.** Two tasks whose masked names have no words match each other. v2: empty word sets
    never match by name. The ledger also keeps the latest name words (the old kept the first words but the latest
    name), so a slow rename keeps tracking.
11. **Leak scrubbing depends on old maskers** (`maskText`, `maskNamesForStorage`). v2: names arrive masked from
    understanding; `names.ts` still strips emails, URLs, pseudonym tokens and digits, and the repository refuses a
    write with an email or a URL (old `assertDerivedOnly`, kept).
12. **GET routes write.** Every review GET folds the analysis into memory. v2: handlers only read; a job writes.
13. **Untyped figures.** Day totals mix `{value, arithmetic, eventIds}` with bare numbers. v2: every number is a
    `Figure { id, value, unit, arithmetic, evidence[], source_purged_at }`, id = `fig_` + 16 hex of sha256(JCS).
14. **Goal ids** are `sha256(text)`, so re-adding an archived goal reuses its id. v2: DATA_MODEL rule (text ‖
    `created_at`); the same active text keeps its id; removed goals are archived, not deleted.
15. **`<`/`>` in goals were silently replaced.** v2: a goal or role with `<`, `>` or a control character is a 400;
    `userContextBlock` still strips them (defence in depth).
16. **Errors** were `bad_request`/`method_not_allowed`. v2: the closed code list in API.md.
17. `switchIds.push(eventIds[0]!)` pushes `undefined` for a span without events. v2 skips it.
18. **Kinds from URL paths** (`docs.google.com/spreadsheets`): v2 has only the host and a `<doc:h_…>` pseudonym, so
    `docs.google.com` is `docs` (sheet and doc cannot be told apart; noted in Known gaps).
19. **Sameness blend is not idempotent.** `revise` blends the stored mean with the fresh one, so merging one window
    twice moves it. v2 keeps sameness per day in the evidence and recomputes the weighted mean; merge also derives
    every rate from the evidence instead of trusting a stored `rate`.

Found by the independent review (fixed, with tests): links without a scheme (`github.com/a/b`) passed the name
scrubber; `checkNarrative` still accepted numbers from dates and arithmetic constants (it now knows only figure values,
numeric fields and list lengths); a task with no instances broke the job; a bad `%` escape threw instead of a 400;
`figure_index` lost a figure shared by two records; app names were not scrubbed; concurrent profile PATCHes now take a
per-member advisory lock.

## 3. Sealed files → Postgres tables

| Old file under `$OFFLOAD_HOME` | v2 table (DATA_MODEL 4, 6) |
|---|---|
| `profile.json.enc` | `profiles`, `goals` (goals archived, never deleted) |
| `memory/ledger.json.enc` | `task_ledger` (hashed signatures, masked name words, centroid) |
| `memory/days/*.json.enc` | `day_records`, `episodes` |
| `memory/weeks/*.json.enc` | `week_records`; ranked candidates → `opportunities` (`source = 'finder'`) |
| month / quarter computed on read | `month_records`, `quarter_records` |
| `memory/user-model.json.enc` | `propositions` (one row per version; `revision_group` replaces `supersedes` edges) |
| `memory/answers.json.enc` | `review_answers` (latest wins per week and subject) |
| (none) | `figure_index` |

Every table: `tenant_id`, `member_id`, `ENABLE` + `FORCE ROW LEVEL SECURITY`, `tenant_isolation`, and the restrictive
`member_isolation` (ADR 0013). `offload_app` gets no DELETE on `propositions`, records, ledger, episodes, profiles,
goals or answers: rows end with `invalid_at` / `expired_at` / `archived_at`; deletion is the forget path (M7).
Migrations live in `services/brain/sql/NNNN_*.sql`; `packages/db`'s runner adopts them later. Vectors are `real[]`
until pgvector is installed (the local Postgres has no `vector` extension); the cosine is exact and done in code, as
ADR 0019 asks (exact scan, no HNSW).

## 4. Stubs and ports for other streams' areas

| Port (in `services/brain`) | Stands in for | Owner |
|---|---|---|
| `UnderstandingWindow` (`src/user-model/ports.ts`): spans, induced tasks, instances, centroids | sessionize/induce output | m5-01 |
| `FixEstimate` (weekly saving, setup hours, rule confidence, work kind) | fix rules and options | m5-04 |
| `CompleteText` (prompt → text) for the weekly sentence | model router | W1-F (m5-03) |
| `RunInTenant` + `bunRunInTenant` (`src/store/tenant.ts`): one transaction, `SET LOCAL app.*` | `withTenant` | W1-C (m1-03) |
| `jcs()` (`src/records/jcs.ts`), RFC 8785 for figure ids | contracts JCS | W1-E |
| `applyUserModelMigrations` (`src/store/migrate.ts`) | migration runner, roles | W1-C |
| `rawTtlDays` parameter (default 30) | `packages/db/src/config.ts` | W1-C |
| `UserModelAuth` `{ tenantId, memberId, principalId, tenantRole }` passed to handlers | verified session / token | W1-E/services/api |
| Profile, record, review shapes as TypeScript types in `services/brain` | zod contracts | W1-E (`packages/contracts`) |

No FK to `tenants`, `members` or `workspaces` yet (those tables do not exist on `main`); the adopting migration adds
them. Tests create a unique schema and unique roles per file and drop them after (the CI database is shared).

For the durable step that calls `runMemberUpdate` (W1-C, m5-05): `TimezoneMismatchError` (`code: "timezone_mismatch"`,
`retryable: false`) is not retryable. The same window fails on every retry; the step rebuilds the window in the
profile's timezone (or gives up and records why). The handlers read the request body before `RunInTenant` opens.
While `profiles.learning_paused` is true the job returns `paused: true` and writes nothing (ONBOARDING 11.12).

## 5. Privacy and numbers

- No window title, text snapshot, URL or email enters any R-model table: names go through `names.ts`; spans' titles are
  read for nothing; evidence holds observation ids only. A p43b test dumps every row of every table and searches it
  for the fixture's raw titles, texts, URLs and emails.
- Goals reach a model only inside `<user_context>` (the weekly sentence prompt is the one prompt built here).
- Every number shown is a `Figure` computed in code. The weekly sentence is model words; `checkNarrative` refuses a
  number not in the week record, and a code sentence is used instead.
- No log lines are written by this module.

## 6. Dropped, and why

- Sealed files, `memory/seal.ts`, the `memory`/`profile` brain keys, `usermodel/store.ts` (Postgres now).
- `memory/cli.ts`, `memory/update.ts` as written, `GET /memory/model`, the local `/review/*` and `/profile` routes.
- `sequence` propositions, `precedes` and `supersedes` edges (M7; versions are linked by `revision_group`).
- `usermodel/workflows.ts`: task "workflows" duplicate week-record tasks and opportunities, and chains need sequence
  propositions (M7). No v2 table holds them. MIGRATION 5.4 is corrected in p43a.
- Old `rankSuggestions` (insight score × confidence × persistence): replaced by the goal-weighted score.
- Goal drift and realized stubs (M4/M7). Pronouns: v2 has no pronoun in the profile; text says "They".
- `s14` `user-context.json` migration: v2 has no such file.

## 7. Known gaps (left for later slices)

`checkNarrative` reads cardinal number words (`three`, `forty-two`) like digits and refuses multipliers, fractions and
scales (`twice`, `half`, `hundred`); ordinals (`first`, `third week`) other than `third` are not read. Goal embeddings and task centroids need the local
embedder (m5-01); until then `bestGoal` gets vectors from the caller. `competes` has no producer yet. Sheets vs docs on
`docs.google.com` cannot be told apart. The figure-evidence route (`GET /v1/figures/{id}/evidence`) is not built here.
Any alignment above 0 counts as advancing a goal (the formula sets no floor; real embeddings will need one, an owner
call). Re-analysing a day with different instance ids leaves the old episode rows: `offload_app` has no DELETE and
R-model rows are kept until forget, so retention does not clean them. Readers therefore take a day's episodes only
through `day_records.episode_ids` (DATA_MODEL section 4); orphans stay until forget (M7). Episode ids are `ep_` + the
instance id, which understanding must keep globally unique (`ports.ts`). The job refuses a window whose timezone is not
the profile's (`TimezoneMismatchError`), so days are always profile days.
