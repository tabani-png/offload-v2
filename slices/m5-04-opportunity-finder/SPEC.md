---
id: m5-04-opportunity-finder
title: Fix rules turn a ranked task's evidence into one to three proposed fix options with code-computed estimates and connector resolution, and the finder stores opportunities with their options
milestone: M5
status: in_progress
depends_on: [m5-01-understanding, p43b-user-model-store-api]
parallel_safe: false
human_gated: false
model_tier: opus
size: M
parallel_group: M5-B
owns: [services/brain/src/opportunities/**, services/brain/sql/0002_fixes.sql, services/brain/tests/m5-04-opportunity-finder/**]
verify: bash slices/m5-04-opportunity-finder/verify.sh
min_tests: 31
paths_in_scope: [services/brain/src/opportunities/**, services/brain/src/store/job.ts, services/brain/src/store/repository.ts, services/brain/src/store/migrate.ts, services/brain/sql/0002_fixes.sql, services/brain/src/records/day-record.ts, services/brain/src/records/kinds.ts, services/brain/src/understanding/job.ts, services/brain/src/index.ts, services/brain/tests/m5-04-opportunity-finder/**, docs/API.md, docs/ARCHITECTURE.md, docs/DATA_MODEL.md, docs/GLOSSARY.md, docs/ROADMAP.md, slices/m5-04-opportunity-finder/**]
paths_out_of_scope: [ee/**, apps/**, packages/**, services/api/**, services/runtime/**, services/broker/**, services/builder/**, services/brain/src/models/**, services/brain/sql/0001_user_model.sql, services/brain/tests/p43a-user-model-core/**, services/brain/tests/p43b-user-model-store-api/**, services/brain/tests/m5-01-understanding/**, docs/adr/**, .github/**, slices/m5-04-opportunity-finder/STATUS.md]
red_tests: [EVIDENCE, CONNECTOR, RULE, ESTIMATE, OPTIONS, RANK, PERSIST, FINDER]
---

# m5-04-opportunity-finder

## Summary
Top fix 4 of the end-to-end test of `main` on stand-in data (2026-11-22, report kept outside the repo): the finder
only ranks. Nothing produces `FixEstimate`, so the faithful pipeline ranks **0** opportunities, and the only estimator
in the repo is a test stand-in ("half the hours, 3 h setup"). This slice builds the **fix rules**
([ARCHITECTURE section 6](../../docs/ARCHITECTURE.md#6-opportunity-finder) "Fix rules: kinds, saving, confidence,
effort", [section 7](../../docs/ARCHITECTURE.md#7-fix-designer) "Options"): a table of rule kinds that maps an induced
task's evidence (systems it touches, frequency, duration, cadence) to one to three proposed **fix options**, each with
an estimate (weekly hours saved, setup hours, payback, confidence) computed in code as Figures
([ADR 0003](../../docs/adr/0003-numbers-come-from-code.md)), and each step's connector resolved in the order of
[ADR 0033](../../docs/adr/0033-pinned-connector-resolution-and-launch-catalog.md) (MCP, then Composio, then a direct
API, then the browser). `rankOpportunities` then ranks real estimates, and the opportunities are stored with their
options (`fixes`) so the API (m5-05) can read them. It moves the M5 exit criterion "Today shows one ranked suggested
fix from observed work with 2 or 3 options".

It **proposes**. It does not pin connections, capture fixtures, write a brief, a check set or a held-out check (m2-04,
m2-05, on hold), and no model is called.

## Contract
- No new dependency. Migration `services/brain/sql/0002_fixes.sql`:
  - `episodes.hosts text[] NOT NULL DEFAULT '{}'`: the hosts of the instance's spans (bare hosts, C1 metadata like
    `task_ledger.host`), so a week's task evidence knows which web apps a workflow touches.
  - Table `fixes` (DATA_MODEL section 6) with `member_id` added for the member wall (MI, as every brain table):
    `(tenant_id, id)`, `member_id`, `workspace_id`, `opportunity_id` (FK `opportunities`, cascade), `option_no` 1..3
    (unique per opportunity), `kind` (fix kind), `rule` (rule kind), `recommended`, `title`, `detail` (code
    templates, masked words only), `estimate` (Figure, hours per week), `confidence` (0..1), `effort_hours` (setup
    hours), `figures jsonb` (`weekly_hours_saved`, `setup_hours`, `payback_weeks`, `confidence`, each a Figure),
    `steps jsonb` (connector plan), `chosen_at`, `created_at`. RLS as 0001 (`tenant_isolation`, restrictive
    `member_isolation`); `offload_app` gets SELECT, INSERT, UPDATE, DELETE (open options are replaced).
- Exported from `@offload/brain`, for m5-05, m1-06 and e2e-01:
  - `fixRules(opts?: { catalog?: TenantCatalog }) → FixRules` with `propose(evidence: TaskEvidence) → FixProposal | null`.
  - `TaskEvidence { task_key, name, iso_week, minutes, instances, median_minutes, days, systems: System[], cadence:
    Cadence | null, episode_ids }`; `System { id (bare host for `web`, bundle id for `desktop`), surface: "web" |
    "desktop", work_kind }` (no separate `app_bundle_id`: the id holds it, review 2 finding 6); `Cadence { kind: "daily" | "weekly", weekday, hour }`.
  - `buildTaskEvidence(input: { week, episodes, timezone }) → TaskEvidence[]` (pure).
  - `FIX_RULES` (the rule table), `FIX_KIND_TABLE` (share, review minutes, setup, confidence per fix kind).
  - `resolveConnector(system, catalog?) → { provider, label, adapter: "mcp" | "composio" | "openapi" | "browser" |
    null, runs_on: "cloud" | "device" }`, `LAUNCH_CATALOG`, `ADAPTER_ORDER = ["mcp", "composio", "openapi", "browser"]`.
  - `FixOption { option_no, kind, rule, recommended, title, detail, steps, figures: { weekly_hours_saved, setup_hours,
    payback_weeks, confidence } }`, `FixProposal { task_key, rule, leave_alone_first, options, estimate: FixEstimate }`.
  - `FixEstimate` gains `option?: FixOption`. The stand-in `estimateFor` path stores one option built from the bare
    estimate (`bareOption`, `rule: "estimate"`, no steps). An estimate `fixes` cannot store (`leave_alone`, an unknown
    kind, no saving) gives no option, and a re-ranked opportunity then keeps none (review 2 finding 2).
  - `runMemberUpdate` input gains `fixRules?: FixRules`; `UnderstandingDeps` gains `fixRules?` (passed through, withheld
    without a workspace, as `estimateFor`). `estimateFor` wins when both are given.
  - Repository: `saveOpportunities(tx, { ..., options? })` stores each ranked opportunity's options;
    `listOpportunityViews(tx, { isoWeek?, state? })` and `getOpportunityView(tx, id)` return the API `Opportunity`
    shape: `{ id, source, task_key, title, description, iso_week, rank, state, not_now_until, goal_id, goal: { id,
    text } | null, score, factors, leave_alone_first, options[] }`, each option `{ id, option_no, kind, rule,
    recommended, title, detail, steps, figures, estimate, chosen_at }` with `estimate` = `figures.weekly_hours_saved`.
    These carry every field the Mac's `Opportunity` and `FixOption` decoders read (`BuildsModels.swift` on `main`)
    except `missing_connections`, which nothing produces before `needs_connection` exists (review 2 finding 1); `listWeekEpisodes(tx, from, to)` reads episodes through `day_records.episode_ids`.
- API.md `Opportunity` and `FixOption` shapes are written down (the routes are m5-05's). `listOpportunityViews`
  without `isoWeek` answers the latest week with opportunities.
- `fixes` is added to `MEMBER_ISOLATED_TABLES` (store/migrate.ts), so p43b's RLS and privacy tests cover it.

## Design note
1. **Evidence** (`opportunities/evidence.ts`, pure). For the latest week of the run, the job reads the task_instance
   episodes of the last 8 weeks through `day_records.episode_ids` (never by `episodes.day` alone, m5-01 known limit).
   Per week task: `minutes`, `instances`, `median_minutes` from the week record (the same Figures the score uses);
   `days` = distinct days with an instance this week; **systems** = the episodes' hosts (surface `web`) plus their
   apps that are neither a browser nor a stand-in app (`recording.unknown`, `screenwatch.screen`; surface
   `desktop`); a stand-in says nothing about the work. `work_kind` by `kindOf` (records/kinds.ts). **Cadence**:
   `daily` when this week has one instance on each of at least 3 days, starting within a 2 h band (member timezone);
   `weekly` when every week of the 8 with an instance has exactly one, at least 2 such weeks, on the same weekday,
   within a 2 h band. The hour is the median start's hour.
2. **Fix rules** (`opportunities/rules.ts`): every rule needs at least 3 instances in the week or a cadence (a
   cadence is repetition seen over days or weeks), and at least one system; tasks whose systems are all `code`,
   `meeting` or `chat` get none. A cloud kind (`api_integration`, `agent_workflow`, `scheduled_routine`) is offered
   only when at least one step has a connector (MCP, Composio or a direct API); otherwise it would be browser
   automation under another name. First match wins:

   | Rule kind | Matches | Options, in order |
   |---|---|---|
   | `report_assembly` (repeated report assembly) | a cadence, a `sheet` or `docs` system and at least 2 systems | `scheduled_routine`, `script` |
   | `email_triage` (repeated email triage) | only `email` systems, at least 5 instances, median at most 10 min | `setup_change` (mail rules), `agent_workflow` |
   | `email_to_records` | an `email` system and another system | `agent_workflow`, `api_integration`, `browser_automation` (if every system is web), `script` (if a desktop system) |
   | `app_to_app_copy` (repeated copy between apps, e.g. two web apps) | at least 2 non-email systems | `api_integration` (connector pair), `browser_automation` (if every system is web), `script` (if a desktop system) |
   | `single_app_entry` | one system of kind `sheet`, `docs`, `browse` or `other` | `browser_automation` (web) or `script` (desktop) |

3. **Connectors** (`opportunities/connectors.ts`): `LAUNCH_CATALOG` (ADR 0033's apps as data: hosts and bundle ids
   to provider and methods). Each step takes the first method in `ADAPTER_ORDER` the catalog lists for its app and the
   tenant filter allows. A web app not in the catalog goes through the `browser` (runs on the device, attended,
   ARCHITECTURE section 12); a desktop app not in the catalog has no connector (`adapter: null`, runs on the device
   through the actuator). The proposal uses the launch catalog; the verified catalog (m2-02) and the pins belong to
   the fix designer (m2-05).
4. **Estimate** (`opportunities/estimate.ts`), per option (`setup_change` steps are applied by the user on the device;
   `browser_automation` web steps use the `browser` adapter on the device; `script` and the cloud kinds resolve each
   step's connector), from `FIX_KIND_TABLE` (fixed constants, code only):
   - weekly hours saved = max(0, minutes × share − instances × review minutes) / 60, rounded to 0.01;
   - setup hours = base + per step × steps + 1 per browser step (in a cloud kind) + 0.5 per device step (in a cloud
     kind);
   - confidence = kind confidence × instances factor (1 at 5 or more or with a cadence, else 0.85) × days factor (1
     on 2 or more days or with a cadence, else 0.85) × 0.85 per browser step × 0.9 per device step (cloud kinds), clamped to 0..1, rounded to 0.001;
   - payback weeks = setup / weekly saving (`paybackWeeks`).
   Each is a Figure with its arithmetic; evidence = the week record and the instances' episodes. An option saving
   nothing is dropped; no option left = no proposal.

   | Fix kind | Share of the task's time | Review min per instance | Setup base h | Setup per step h | Confidence |
   |---|---|---|---|---|---|
   | `api_integration` | 0.8 | 0.5 | 2 | 1 | 0.7 |
   | `agent_workflow` | 0.7 | 1 | 3 | 1 | 0.6 |
   | `scheduled_routine` | 0.85 | 1 | 2 | 0.5 | 0.75 |
   | `script` | 0.5 | 0.5 | 1.5 | 0.5 | 0.55 |
   | `browser_automation` | 0.6 | 1 | 3 | 1 | 0.5 |
   | `setup_change` | 0.3 | 0 | 0.5 | 0 | 0.6 |

5. **Options** (`opportunities/rules.ts`): one to three of the rule's surviving kinds; those saving at least 0.5 h per
   week first, then by option value = saving × confidence ÷ max(1, payback) (the score's own factors), ties by the
   rule's order; numbered from 1; option 1 is `recommended` (so it saves at least 0.5 h per week) unless no option
   does, then `leave_alone_first` is true and none is recommended (ARCHITECTURE section 7). Title and detail are code
   templates from masked words only (host, app label, counts, plain mechanics: "through a connector", "in your
   browser, on your Mac", "on your Mac"); connector products stay in `steps`.
   The proposal's `estimate` (the `FixEstimate` `rankOpportunities` scores) is option 1's numbers.
6. **Job** (`store/job.ts`): with `fixRules`, the latest week's tasks get evidence, proposals and estimates; ranking
   is unchanged (`rankOpportunities`); `saveOpportunities` stores the top 5 and upserts their options by
   `(opportunity_id, option_no)` (stable ids, so a re-run leaves identical rows), drops options past the new count,
   and touches options of an opportunity only while it is `open` and none is chosen. An open finder opportunity that
   leaves the top 5 is deleted with its options. Option figures are indexed in `figure_index` under the opportunity's
   record, so "how it was counted" resolves them.

Privacy: evidence holds bundle ids, bare hosts, counts and episode ids; no title or text reaches the rules. Option
text is built from the masked task name and catalog labels and passes the repository leak guard.

## Red tests (write these first, run them, see them fail)
Tests live in `services/brain/tests/m5-04-opportunity-finder/`. Postgres tests skip without `DATABASE_URL` (verify.sh
requires it).

| Tag | Test name |
|---|---|
| EVIDENCE | EVIDENCE: a week's evidence counts instances, minutes and days and lists hosts and desktop apps as systems |
| EVIDENCE | EVIDENCE: browsers and stand-in apps are not systems |
| EVIDENCE | EVIDENCE: one instance a day at the same hour is a daily cadence; the same weekday across weeks is weekly |
| CONNECTOR | CONNECTOR: resolution prefers MCP, then Composio, then a direct API, then the browser |
| CONNECTOR | CONNECTOR: a tenant filter removes methods; an unknown web app goes through the browser and an unknown desktop app runs on the device |
| RULE | RULE: copy between two web apps gets a connector pair through an API integration first |
| RULE | RULE: a report assembled on a cadence gets a scheduled routine |
| RULE | RULE: short repeated mail-only work gets mail rules as a setup change |
| RULE | RULE: mail turned into records in other apps gets an agent workflow, an integration and browser automation |
| RULE | RULE: fewer than 3 instances, or only code, meetings or chat, gets no fix |
| ESTIMATE | ESTIMATE: golden evidence gives the exact options with Figures |
| ESTIMATE | ESTIMATE: every figure's arithmetic reproduces its value |
| ESTIMATE | ESTIMATE: an option that saves nothing is dropped and no option left gives no proposal |
| OPTIONS | OPTIONS: one to three options numbered from 1, the best value first and recommended |
| OPTIONS | OPTIONS: below 0.5 h a week leave alone comes first and no option is recommended |
| RANK | RANK: the fix rules' estimates are ranked and an empty profile keeps their order |
| PERSIST | PERSIST: the update job with the fix rules stores ranked opportunities, their options and episode hosts |
| PERSIST | PERSIST: a re-run leaves identical rows and a task leaving the top 5 loses its open opportunity and options |
| PERSIST | PERSIST: options of a chosen opportunity are not touched and members read only their own |
| FINDER | FINDER: an import of a repeated invoice workflow yields a ranked opportunity with a proposed fix and noise yields none |
| FINDER | FINDER: figures of options resolve through figure_index |
| EVIDENCE | EVIDENCE: start times over 2 h apart, different weekdays, two in one week or an instance 9 weeks back give no cadence (review 1 finding 1) |
| RULE | RULE: browser automation is offered only when every step is a web app (review 1 finding 2) |
| ESTIMATE | ESTIMATE: a bare estimate keeps a storable kind, and gives no option for another kind or for no saving (review 1 finding 4) |
| OPTIONS | OPTIONS: the recommended option saves at least 0.5 h a week (review 1 finding 3) |
| PERSIST | PERSIST: without a week the latest week with an opportunity is read, and a state filter applies within it (review 1 finding 5) |
| FINDER | FINDER: without a workspace the fix rules are withheld and no opportunity is stored (review 1 finding 1) |
| PERSIST | PERSIST: each option carries its saving as estimate, and an opportunity its description and goal, in the shapes the Mac decodes (review 2 finding 1) |
| PERSIST | PERSIST: a re-ranked opportunity whose estimate gives no option keeps no stale option (review 2 finding 2) |
| PERSIST | PERSIST: an open opportunity with a picked option is kept when it leaves the top 5 (review 2 finding 3) |
| PERSIST | PERSIST: an option holding an email address or a URL is refused and nothing is stored (review 2 finding 4) |

Review 1 also added assertions to existing tests: device-step cost (ESTIMATE), work-kind priority (RANK), a re-run from
2 options to 1 and a stale episode outside `day_records.episode_ids` (PERSIST), no connector product in option text
(ESTIMATE).

## Test plan
Pure tests on hand-built `WeekRecord`s and `Episode`s (`tests/m5-04-opportunity-finder/fixtures.ts`). Postgres tests
use a per-file brain schema and app role (as p43b), and the FINDER test drives `runUnderstanding` with m5-01's
synthetic invoice import (mail → web accounting app → spreadsheet, repeated over days, plus noise clips) on the
capture tables (`pgTenantFixture`).

## Out of scope
Instant read (needs connections, m2-02/m2-03), manual and agent opportunities (m2-01, M8), pinning, fixture capture,
brief, check set and held-out check (m2-04, m2-05, on hold), the opportunity routes and Today (m5-05), wiring the job
into `offload serve` (m1-06), `remove_step` and `small_app` rules, track record from run savings (m4-03).

## Verify
`bash slices/m5-04-opportunity-finder/verify.sh` (needs `DATABASE_URL` to a disposable Postgres 17).

## Scope changes
- ROADMAP m5-04 also lists **instant read**; it needs connections and the broker (m2-02, m2-03), which are not built.
  Deferred to a later slice; `opportunities.source = 'instant_read'` stays unused.
- `fixes` gets `member_id` (DATA_MODEL section 6 had none) so the restrictive member wall applies like every brain
  table, plus `rule`, `figures` and `steps`; `episodes` gets `hosts` (DATA_MODEL section 4). DATA_MODEL is updated.
- PERSIST "options of a chosen opportunity are not touched" was strengthened after the red commit (self-review
  mutation check): it now also keeps an `open` opportunity whose option has `chosen_at`, so each of the two guards in
  `saveOptions` is tested on its own. No assertion was weakened.
- Review 1 (changes after the red commit, each with red tests first in bf541e8):
  - Finding 2: `browser_automation` is offered only when every system is a web app (it was "a web system"). The
    mixed mail case in RULE now expects `script` only; a browser cannot drive Mail or Excel.
  - Finding 3: options saving at least 0.5 h per week come first, so the recommended option always clears the
    leave-alone threshold. The OPTIONS ordering assertion checks "clears first, then by value" instead of "by value".
  - Finding 4: `bareOption` keeps any kind `fixes` can store (`StoredFixKind` adds `small_app`, `remove_step`) and gives
    no option for `leave_alone`, an unknown kind or a zero saving (no false payback arithmetic).
  - Finding 6: option text says "through a connector" / "in your browser, on your Mac" instead of MCP, Composio or
    direct API; the golden detail strings changed accordingly.
  - Finding 1 asked for a 4-kind case asserting the 3-option cap. After finding 2 no rule yields more than 3 kinds
    (browser automation needs all-web steps, a script needs a desktop step), so `MAX_OPTIONS` is a guard with no
    reachable input and no test can exercise it.
  - Finding 7: the explicit delete of a leaving opportunity's options is removed (the `ON DELETE CASCADE` does it,
    PERSIST checks), and so is the `recommended = false` pre-clear (only option 1 is ever recommended).
- Review 2 (red tests first in b137c7f): the opportunity view gains `description`, `goal { id, text }` and per option
  `estimate`, the fields the Mac's Today decoders on `main` read (common.md: no parallel contract); an open
  opportunity with a picked option is no longer deleted when it leaves the top 5 (it stays, unranked, like its
  options); an estimate that gives no option clears the earlier run's options instead of leaving them attached.
- The stand-in `estimateFor` path (p43b tests) also stores one option, built from the bare estimate, so every ranked
  finder opportunity has at least one option row.

## Progress
- [x] SPEC, verify.sh, ROADMAP link (375d690)
- [x] red tests: all 21 seen failing (`not implemented`, missing `fixes` table)
- [x] connectors, evidence, rules, estimate, options (d95edd3)
- [x] migration 0002, repository, job wiring (46205ec): 21 slice tests pass, full suite 671 pass
- [x] docs: ARCHITECTURE section 6 (fix rules), DATA_MODEL sections 4 and 6, API.md `Opportunity`, GLOSSARY
- [x] self-review: mutation spot-checks (adapter order swapped → CONNECTOR, RULE fail; cloud-kind connector gate
  removed → RULE, ESTIMATE fail; episode hosts dropped → PERSIST, FINDER fail; stand-in filter removed → EVIDENCE fails;
  either saveOptions guard removed → PERSIST fails)
- [x] `bash slices/m5-04-opportunity-finder/verify.sh` PASS (21 slice tests, 671 in the full suite);
  `SLICE_UPSTREAM=$(git merge-base HEAD origin/chain/m5-01-understanding) bash scripts/verify-all.sh` green
- [x] review 1 (CHANGES): findings 2, 3, 4, 6 fixed with red tests first (bf541e8, then fc3ac0a); finding 1 and 5
  tests added (db4edb8; 11 of 11 reverted guards now fail a test); finding 7 cleanup; docs (API.md, ARCHITECTURE 6)
- [x] after review 1: `verify.sh` PASS (27 slice tests, 677 in the full suite); `verify-all` green with
  `SLICE_UPSTREAM=$(git merge-base HEAD origin/chain/m5-01-understanding)` (two earlier runs each had one timeout in
  untouched packages under load: contracts round-trip 11.5 s, durable cron 25 s; the rerun was green)
- [x] review 2 (CHANGES): findings 1, 2, 3 fixed with red tests first (b137c7f, then 7f174e6); finding 4 tests
  (eef0db8; both reverted guards now fail a test); findings 5, 6, 7 recorded below and in API.md
- [ ] review 3, then `status: done`

Known limits (for the next slices):
- Steps are listed in system id order, not in the workflow's order: episodes keep the set of apps and hosts, not
  their sequence. The fix designer (m2-05) orders steps from the instances' spans.
- A desktop mail app (Mail, Outlook) has no connector here: the mailbox behind it is unknown until the pseudonym match
  or a connection names it (m5-06, m2-02), so its step runs on the device and cloud kinds need another connected step.
- Weekly minutes are the week record's observed minutes, not extrapolated: a partial week (an import of 3 days)
  estimates from what was seen.
- The launch catalog is ADR 0033's list as data; every entry is "unverified" until spike S5 / m2-02 flips it. The
  proposal does not filter on verification (the fix designer must, before pinning).
- Only the latest week of a run is ranked (unchanged from p43b).
- For m5-05 and the Mac owner (review 2 finding 5): the Mac's Today card ignores `leave_alone_first`. It always puts
  "Leave it alone" last and preselects the recommended option, else option 1, so when no option saves 0.5 h a week it
  preselects option 1. Showing "leave it alone" first needs a Mac change (not this chain's files) or a field the card
  decodes; until then `leave_alone_first` is information only.
- For m5-05: the view has no `missing_connections` (the Mac defaults it to `[]`); the answer route maps `option_id` to
  `fixes.id`.
- On the chain's own invoice fixture (desktop Mail, `app.ledgerly.example`, desktop Excel; review 2 finding 7) no step
  has a connector, so the cloud kinds are gated out and browser automation is excluded (not every step is web): the
  proposal is one option, a script. e2e-01 should assert "at least one proposed fix", not 2 or 3 options. A fixture
  using web Gmail (`mail.google.com`) gets an agent workflow and an integration as well. ROADMAP M5's "2 or 3 options"
  holds for workflows with a connected app, not for this one.
