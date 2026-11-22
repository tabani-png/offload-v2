---
id: p43a-user-model-core
title: User model core in services/brain - task ledger with stable task keys, day records and episodes, week, month and quarter records, propositions with bi-temporal merge, goal-weighted opportunity score, profile rules, review answers and the user_context block (port of old PR #43)
milestone: M5
status: done
depends_on: []
parallel_safe: false
human_gated: false
model_tier: opus
size: L
parallel_group: M5-A
owns: [services/brain/**]
verify: bash slices/p43a-user-model-core/verify.sh
min_tests: 55
paths_in_scope: [services/brain/**, slices/p43a-user-model-core/**, slices/p43b-user-model-store-api/**, NOTICE, docs/API.md, docs/DATA_MODEL.md, docs/MIGRATION.md]
paths_out_of_scope: [ee/**, apps/**, packages/**, services/api/**, services/runtime/**, services/broker/**, services/builder/**, docs/adr/**, .github/**, package.json, bun.lock]
red_tests: [LEDGER, OBSERVE, DAY, LEAKS, WEEK, THEIL-SEN, MONTH, QUARTER, NARRATIVE, SCORE, PROPOSE, LONG-TERM, INVALIDATE, SUPERSEDE, REVISE, MERGE, PROFILE, PROMPTS, PRIVACY, REVIEW]
---

# p43a-user-model-core

## Summary
Ports the pure logic of old PR #43 (`feat/user-model-gum-graphiti`, s36 user memory) into `services/brain`, following
[MIGRATION 5.4](../../docs/MIGRATION.md#54-pr-43-featuser-model-gum-graphiti-s36-user-memory). It moves the
[M5](../../docs/ROADMAP.md#m5-observed-loop) exit criteria for the task ledger, day and week records, the narrative
check and the opportunity score, and the [M7](../../docs/ROADMAP.md#m7-user-model-depth) ones for propositions and
month records. Implements [ARCHITECTURE sections 5 and 6](../../docs/ARCHITECTURE.md#5-cloud-brain-and-user-model) and
[ADR 0003](../../docs/adr/0003-numbers-come-from-code.md). No I/O: storage and HTTP are p43b. Design, old-to-new file
map, the bugs fixed and the stubs: [DESIGN.md](DESIGN.md).

## Contract
- Delete `services/brain/tests/smoke.test.ts` (the TODO marker is replaced).
- No new dependency. Hashes use `node:crypto`; time zones use `Intl`.
- Input port (stands in for m5-01 understanding): `UnderstandingWindow { timezone, days[], spans[], tasks[] }` in
  `src/user-model/ports.ts`. Spans carry a masked `title` that this module never stores.
- Task ledger (`src/user-model/ledger.ts`): `resolveTaskKeys(prior, window)`. Match order: same hashed signature; else
  same kind, app and host with masked-name Jaccard ≥ 0.5 (empty word sets never match); else centroid cosine ≥ 0.85;
  else a new `k_` + 12 hex key. Bigger tasks claim keys first; a key is used at most once per window.
- Records (`src/records/`): `buildDayRecords(window, keys, now)` gives one `DayRecord` per closed day in the member's
  timezone and `Episode`s (`task_instance` per instance, `focus_block` per run of one task with gaps under 2 min lasting
  ≥ 25 min). `buildWeekRecord` (baseline = median of the task's minutes in the 8 calendar weeks before, over the weeks
  it was present; status `new`, `recurring`, `gone`), `buildRollup` for months (weeks whose Monday is in the month,
  persistent in ≥ 75% of recorded weeks) and quarters (≥ 8/13), Theil-Sen slope over (week index, minutes) with 3 or
  more weeks. Every number is a `Figure { id, value, unit, arithmetic, evidence[], source_purged_at }`, id = `fig_` +
  16 hex of sha256(JCS(figure without id)).
- Narrative (`src/records/narrative.ts`): `checkNarrative(text, record)` (digits and cardinal number words must be
  record values; multipliers, fractions and scales are refused), `weekSentence(record)` (code sentence),
  `weekNarrativePrompt(record, userContext)`, `writeWeekSentence(record, userContext, complete)`.
- Propositions (`src/user-model/{propose,merge}.ts`): kinds `repeats` and `time_share` (no `sequence` before M7);
  `score = 0.45·min(1, days/10) + 0.35·(1 − e^(−instances/6)) + 0.2·sameness`, `confidence = clamp(round(1 + 9·score),
  1, 10)`, `decay = clamp(round(1 + 9·min(1, days/14)), 1, 10)`; a rate change over 50% starts the next version in the
  same `revision_group` and ends the old one (`invalid_at` = max(old `valid_at`, new `valid_at`), `expired_at` = now);
  a belief not seen for 7 analysed days ends (`invalid_at` = last seen). Nothing is deleted.
- Score (`src/opportunities/score.ts`): `weeklyHoursSaved × persistence × goalWeight × confidence ÷ max(1,
  paybackWeeks) × declinePenalty` with `paybackWeeks = setupHours / weeklyHoursSaved` from the `FixEstimate`,
  `confidence = rule confidence × track record`, drain boost +0.1 to persistence in weeks 1 to 4, `not_now` for 4
  weeks, `never` and `leave_alone` until a later answer, all overridden by a rise of 50% or more over baseline. Top 5.
- Profile (`src/profile/profile.ts`): `applyProfilePatch` with the rules in API.md (goals ≤ 3, each ≤ 80 chars, one
  line, no `<` or `>`; enums; `HH:MM`; IANA timezone; unknown or read-only fields refused); goal id per DATA_MODEL.
- Review (`src/review/`): `parseReviewAnswer`, latest answer wins, `buildWeekReview` → `{ iso_week, sentence, tiles[],
  goals[], questions[] }` (at most 4 questions).
- `<user_context>` (`src/understanding/context.ts`): goals reach a prompt only inside this block.

## Red tests (write these first, run them, see them fail)
Folder: `services/brain/tests/p43a-user-model-core/`. Carried from old `brain/tests/s36-user-memory/` (restated for
v2) unless marked new.

| Tag | Asserts |
|---|---|
| LEDGER | two weeks of the same work keep ≥ 95% of active time on the same keys; renamed-but-same maps to the old key; a new task gets a new key, two tasks in a window never share one; deterministic; centroid cosine ≥ 0.85 matches, below does not (new); empty names do not match (new) |
| OBSERVE | per-day counts add up to the instances; share is the task's part of the window's active time |
| DAY | one record per closed day, minutes match the spans; focus blocks, switches, per-task numbers, deterministic; days are member-timezone days (new); every total is a Figure with a JCS id (new); episodes per instance and per focus block (new) |
| LEAKS | episode names have no emails, digits, URLs or raw titles |
| WEEK | ISO labels; hours are the sum of day records with arithmetic; new/recurring/gone and vs baseline; baseline over 8 calendar weeks and `weeks_observed` uncapped (new) |
| THEIL-SEN | median of pairwise slopes; a missing week keeps its place (new) |
| MONTH | weeks by Monday, persistence, trend; one week gives no trend and says so |
| QUARTER | the weeks of the quarter |
| NARRATIVE | numbers in the record pass, others are refused; digits in ids are not known numbers (new); a refused sentence falls back to the code sentence (new) |
| SCORE | the formula; declined is 0 unless +50%; empty profile changes nothing; payback from the estimate (new); `not_now` 4 weeks, `never`/`leave_alone` until changed (new); a goal answer sets alignment 1; empty profile keeps the fix-rule order, top 5 with factor Figures; alignment from goal cosine |
| PROPOSE | third-person repeats text with the counts; computed 1..10 confidence and decay; bi-temporal fields; time share, no sequence; deterministic |
| LONG-TERM | week 1 evidence kept; confidence does not drop for a pattern seen again |
| INVALIDATE | absent pattern ends at last seen and is expired, not deleted; a gap with no analysed days ends nothing (new) |
| SUPERSEDE | > 50% rate change starts version 2 in the same revision group; `invalid_at` never precedes `valid_at` (new) |
| REVISE | a similar rate revises the same version, days unioned, counts recomputed |
| MERGE | merging the same window twice is idempotent |
| PROFILE | defaults; partial patch bumps the version; goal ids stable, removed goals archived, re-added gets a new id; every validation error; goal id formula |
| PROMPTS | goals appear once, inside `<user_context>`; a goal cannot close the block |
| PRIVACY | no title, text, URL or email from the window is in the ledger, records, episodes, propositions or ranking |
| REVIEW | answer validation; latest wins; the week review payload |

## Out of scope
Postgres, HTTP, the durable job (p43b). Sessionize and induction (m5-01). Fix rules and options (m5-04). The model
router (m5-03). Entities, facts, `sequence` propositions, forget (M7). Contracts in `packages/contracts` (W1-E).

## Verify
`bash slices/p43a-user-model-core/verify.sh`.

## Scope changes
- `paths_in_scope` also lists `slices/p43b-user-model-store-api/**`: both slices stack on one branch, and this
  slice's scope check runs from its `BASE` to `HEAD`, which includes p43b's slice folder.
- One NARRATIVE assertion was wrong (it accepted a constant from an `arithmetic` string as a known number); the
  review found it and the test now refuses it (ADR 0003).
- `docs/MIGRATION.md` 5.4 is corrected: `usermodel/workflows.ts` is dropped, not ported (DESIGN.md section 6).
