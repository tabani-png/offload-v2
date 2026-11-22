---
id: m3-13-mac-build-progress
title: Build progress on the Mac (builds started on this Mac, a build's steps, status, held-out check, spend against the build cap, the exact-hash OK, build and deploy approvals, measured saving) from the builds API, with a clearly labelled sample build in local backend mode
milestone: M3
status: in_progress
depends_on: [m3-10-mac-recordings-analysis]
parallel_safe: true
human_gated: true
model_tier: sonnet
size: M
parallel_group: M3-E
owns: [apps/mac/Sources/OffloadMac/BuildProgress/**, apps/mac/Tests/OffloadMacTests/M313/**]
verify: bash slices/m3-13-mac-build-progress/verify.sh
min_tests: 60
paths_in_scope: [apps/mac/Sources/OffloadMac/BuildProgress/**, apps/mac/Tests/OffloadMacTests/M313/**, apps/mac/README.md, docs/GLOSSARY.md, slices/m3-13-mac-build-progress/**]
paths_out_of_scope: [ee/**, services/**, packages/**, apps/web/**, docs/adr/**, .github/**, NOTICE, apps/mac/Package.swift, apps/mac/Packaging/**, apps/mac/TestBuild/**, apps/mac/Sources/OffloadMacApp/**, apps/mac/Sources/OffloadMac/OffloadMac.swift, apps/mac/Sources/OffloadMac/Updates/**, apps/mac/Sources/OffloadMac/SelfCheck/**, apps/mac/Sources/OffloadMac/Version/**, apps/mac/Sources/OffloadObserver/**, apps/mac/Sources/OffloadMasker/**, apps/mac/Sources/OffloadStore/**, apps/mac/Sources/OffloadUploader/**, apps/mac/Sources/OffloadImport/**, apps/mac/Sources/OffloadActuator/**, apps/mac/Sources/OffloadMac/Recordings/**, apps/mac/Sources/OffloadMac/Today/**, apps/mac/Sources/OffloadMac/Onboarding/**, apps/mac/Sources/OffloadMac/Permissions/**, apps/mac/Sources/OffloadMac/LocalNow/**, apps/mac/Sources/OffloadMac/NeverWatch/**, apps/mac/Sources/OffloadMac/Design/**, apps/mac/Sources/OffloadMac/Shell/**, apps/mac/Sources/OffloadMac/Analysis/**, apps/mac/Sources/OffloadMac/OnDevice/**, apps/mac/Sources/OffloadMac/Backend/**, apps/mac/Sources/OffloadMac/Navigation/**, apps/mac/Sources/OffloadMac/TodayLive/**, apps/mac/Sources/OffloadMac/WeeklyReview/**, apps/mac/Tests/OffloadMacTests/SmokeTests.swift, apps/mac/Tests/OffloadMacTests/M304/**, apps/mac/Tests/OffloadMacTests/M305/**, apps/mac/Tests/OffloadMacTests/M309/**, apps/mac/Tests/OffloadMacTests/M310/**, apps/mac/Tests/OffloadMacTests/M311/**, apps/mac/Tests/OffloadMacTests/M312/**]
red_tests: [LIST, STEPS, ATTEMPTS, HEADLINE, HELDOUT, BUDGET, PLAN, OKBUILD, INSTALL, SAVING, POLL, SAMPLE, HANDOFF, STATES, FIGURES, COPY, CANCEL]
---

# m3-13-mac-build-progress

## Summary
The mockup's **Build progress** screen (`Build`, mockups `source.canvas.tsx` lines 712 to 820) on the Mac: the builds
started on this Mac, one build's steps and status, its attempts with the frozen and **held-out check** results, spend
against the **build cap** ($4.00), the two exact-hash approvals (**OK, build** from a fix, then the **deploy
approval**, "Install"), and the measured saving after install. In `.cloud` backend mode it reads and posts the builds
API ([API.md "Opportunities, fixes and builds"](../../docs/API.md#opportunities-fixes-and-builds-core), build-loop port
`port/build-loop`, p45a and p45b) through m3-10's `BuildsClient`. In `.local` mode there is no builder on the Mac, so
the screen plays a **clearly labelled sample build** ("Sample data: cloud not connected") and never shows a sample as a
real success. It takes the hand-off from Today (m3-11) and Weekly review (m3-12) through m3-10's
`navigation.pendingBuild`, and replaces m3-10's `BuildProgressScreen` placeholder. ROADMAP m5-06's Mac screen brought
forward (see Scope changes). `human_gated: true`: the owner checks the sample in Local mode, and a real build when a
cloud backend is configured.

## Contract
- **No new dependency, no Package.swift change.** Files under `BuildProgress/` only.
- **`BuildProgress/`**:
  - `BuildProgressScreen(app:)` (the m3-10 entry point, same initialiser): a list of builds on the left and the
    selected build on the right, as `BuildsListView` and `BuildDetailView` over `BuildProgressModel`.
  - `BuildRecordStore` protocol, `UserDefaultsBuildRecordStore` and `MemoryBuildRecordStore`: the builds started on
    this Mac (`build_id`, the opportunity or repeat name, `fix_id`, `started_at`), newest first. There is no list
    route in the API (see Scope changes).
  - `BuildProgressModel` (@MainActor): `builds: [BuildRow]`, `selected`, `detail: BuildDetail?`, `plan: PlanState?`
    (the OK, build step), `installState: InstallState`, `refresh()`, `okBuild()`, `readDefinition()`, `install()`,
    `cancel()`, `replaySample()`; owns the poll task.
  - `BuildDetail` (pure, Equatable), built by `BuildDetail.make(build:fix:outcome:now:)`: `title` ("Building · PR
    pre-read tool"), `headline`, `meter` ("6m 12s · $0.84 of $4.00"), `steps: [StepRow]` (5 rows), `attempts:
    [AttemptRow]`, `heldOut: HeldOutResult`, `saving: SavingLine?`, `actions`, `provenance`.
  - `StepMapping`: the API's `stages[].name` and `state` onto the mockup's five rows:
    1. "Plan locked" · "what it builds and what it must not touch" · "fingerprint 7c41e2" (first 6 hex of the fix's
       `brief_hash`): done once the build exists.
    2. "Checks frozen first": stage `teeth_gate` (running, done or failed, with its `note`).
    3. "Workers testing": stages `worker` and `fan_out`; detail "2 of 3 attempts passing", or "1 failed · builder is
       fixing it" while a failed attempt is followed by another running one.
    4. "Matches what you asked for": stages `verification` and `winner`, with the held-out result.
    5. "Ready to ship" · "install asks you once more": the build's `state` is `ready`.
    Unknown stage names are listed under row 3 with their name, never dropped.
  - `HeadlineMap` (closed, by `state`): `queued` "Waiting to start."; `building` "Building. Tests first.";
    `verifying` "Checking it in a fresh sandbox."; `fanning_out` and `repairing` "One check failed. Fixing it.";
    `ready` "It's built and every check passed."; `failed` "It didn't pass. Nothing was installed."; `capped` "It
    reached the $4.00 cap. Nothing was installed."; `tampered` "A worker changed the checks. The build was stopped.";
    `cancelled` "Cancelled. Nothing was installed."; `infra_failed` "The build service had a problem. This is not
    billed to your cap."; an unknown state "Status: <raw>". The server's `note` of the latest stage is shown under it
    as given. Dots: blue working, amber needs you (`capped`, `tampered`, `infra_failed`, a failed stage), green done,
    red a failed check.
  - `AttemptRow`: "worker 1" (by `ordinal`), outcome dot (`running` blue, `pass` green, `fail` red, `cap`, `tamper`,
    `error` amber), frozen checks ✓ or ✗ from `frozen_pass` and `check_groups`, held-out ✓, ✗ or "not run" from
    `held_out_pass`, spend "$0.31" from `spent_usd`.
  - `HeldOutResult`: `.passed`, `.failed`, `.notRun`, from the winner attempt, else the latest attempt.
  - `BudgetMeter`: elapsed from `started_at` to `ended_at` (or now), "$0.84 of $4.00" from `spent_usd` and `cap_usd`
    (two decimals, half up, formatted in code); at or over the cap the meter is amber.
  - `SampleBuild`: the mockup's build as a fixed, labelled fixture: 5 steps, 8 named workers with one box per check
    (`parse PR diff` 6, `missing-tests rule` 5, `risky-files rule` 7 failing at check 4 then fixed, `summary card` 4,
    `GitHub read-only` 6, `masking` 5, `menu bar entry` 8, `intent check` 6), "47 tests written before any code ·
    fingerprint 7c41e2", 6m 12s and $0.84 of $4.00, played once over the mockup's 92 ticks of 100 ms
    (`SampleTimeline.state(at:)`, pure), Reduce Motion showing the final state, **Replay**.
  - `BuildCopy`: every string of the screen.
- **OK, build** (`.cloud`, from a `.opportunity(id:optionID:)` hand-off): `POST /v1/opportunities/{id}/answer`
  `{ answer: "build", option_id }`; then `GET /v1/opportunities/{id}` until its fix exists (state lines "Designing
  the fix…", `needs_connection` "Connect <apps> first." from `missing_connections`, polled every 5 s, at most 10
  minutes, then "Still designing. Check back later."); `GET /v1/fixes/{fix_id}` shows the plan (brief summary, the
  estimate as "saves 1.4 h/wk, estimated" from its Figure, "build cap $4.00"); **OK, build** posts
  `POST /v1/fixes/{id}/build-approvals` with exactly the four hashes as read (`brief_hash`, `check_set_hash`,
  `held_out_hash`, `fixture_set_hash`) and `cap_usd: 4`, signed (m3-10 `RequestSigner`). 202 records the
  `build_id` in `BuildRecordStore` and selects it; 403 `hash_mismatch` reads the fix again and says "The plan changed.
  Read it again."; 409 `already_running` says "A build of this plan is already running." and shows the list; 403
  `policy_denied` shows its message. Nothing is posted without the person pressing the button.
- **Install** (deploy approval, `.cloud`, only when `state` is `ready` and not `deployed`): **See what changed** reads
  `GET /v1/builds/{id}/definition` and lists its `words`; **Install** is enabled only after the definition was read,
  and posts `POST /v1/builds/{id}/deploy` with `artifact_sha256` and `receipt_hash` from the build and
  `definition_hash` from the definition read, signed. 201 shows "Installed · version 1"; 403 `hash_mismatch` reads the
  build and the definition again: "It changed since you read it. Read it again."; 409 `state_conflict` refreshes. No
  signer: "Installing needs this Mac to be enrolled." and nothing is sent.
- **Measured saving**: before install, "saves 1.4 h/wk, estimated · measured for 4 weeks after you install" from the
  fix's estimate Figure (no number when there is none); after install, `GET /v1/outcomes?month=` for the routine:
  `pending` "measuring · week 2 of 4", `on_track`, `partial` or `under` "saved 1.2 h/wk measured · 1.4 h estimated"
  from the outcome's Figures, `unmeasured` "not measured"; a 404 (route not built yet) "measured after install, from
  M4". hs-1 numbers are the server's; the Mac formats them only.
- **Polling**: `GET /v1/builds/{id}` every 2 s while the state is `queued`, `building`, `verifying`, `fanning_out` or
  `repairing`; stops at any other state or when the screen goes away; on errors it backs off 2, 4, 8 … 60 s and shows
  "Can't reach Offload. Retrying." (the SSE stream `GET /v1/builds/{id}/events` is a later change).
- **`.local`**: the list holds one row, "Sample build", always with the label "Sample data: cloud not connected" on top
  of the detail; **Install** is disabled with "Installing needs the cloud."; a `.localRepeat` hand-off opens it with
  "Building "<repeat>" needs the cloud. This sample shows what a build looks like."; the sample is never written to
  `BuildRecordStore`, never counted, never shown without the label.

## Design note
- **Layout** follows the mockup: header (headline and the mono meter), the five step rows with animated ticks, the
  panel "Workers · each in its own sandbox", then the actions faded until ready ("Install", "See what changed") and
  the saving note. The mockup's per-check boxes exist only in the sample: the API gives each attempt's frozen and
  held-out results, not single checks, so real builds show one row per attempt (see Scope changes).
- **Exact-hash approvals** (ADR 0004, ADR 0032): the hashes posted are exactly the ones read and shown; the Mac never
  computes, edits or caches them across a refresh; a mismatch always re-reads before the person can press again.
  Approvals are never retried automatically.
- **Hand-off**: the model reads `navigation.pendingBuild` once when the screen appears and clears it, so going back
  to Builds later does not start anything again.
- **States**: no builds (`.cloud`): "No builds yet. Press OK, build on a suggested fix in Today."; a build id that
  is gone (404): the row says "This build is no longer available." with **Remove from list**; offline and errors as
  above.
- **Provenance**: `.sample` in `.local` (m3-10's `SampleDataLabel`), `.cloud` otherwise; the two never mix.
- **Pure first, model second, views last.** Everything the screen says is decided by pure types that tests drive
  directly: `StepMapping.rows(build:fix:)`, `HeadlineMap.headline(_:)` and `HeadlineMap.dot(_:)`,
  `AttemptRow.rows(_:)`, `HeldOutResult.of(_:)`, `BudgetMeter(build:now:)`, `Money.usd(_:)` (half up through `Decimal`,
  so 0.845 is "$0.85"), `SavingLine.make(fix:installed:outcome:)`, `SampleTimeline.state(at:)` (the mockup's formula
  ported tick for tick) and `BuildCopy`. `BuildDetail.make(build:fix:outcome:now:name:)` puts them together (the name
  comes from the record: the API's build has none) and `BuildDetail.sample(tick:)` does the same for the sample.
- **Loops are steps.** The model's three timed loops (the build poll, the plan poll, the sample's 100 ms ticks) are a
  step function that returns the next delay or nil (`pollStep()`, `planStep()`, `sampleStep()`), run by one loop over
  an injected `BuildSleeper`. Tests call the steps and the loops with a recording sleeper; nothing waits in real time.
  `appear(pending:)` starts them and `disappear()` cancels them and makes every step return nil.
- **The fix id.** m3-10's `Opportunity` has no `fix_id`, and an option's `id` is its fix id (`FixOption.id`, "the fix
  id"); so the plan step reads the fix named by the hand-off's `option_id`, else the recommended option, else the
  first. While the opportunity is `open`, `chosen`, `capturing_fixtures` or `designing` it says "Designing the fix…";
  in `needs_connection` it says "Connect <apps> first."; in any other state it reads the fix, and a 404 keeps waiting.
- **The measured line** uses the outcome's `ratio` × `estimated_minutes_per_week` ÷ 60 for "saved … h/wk measured"
  (the outcome has no single measured-per-week field; `weeks` holds per-week values whose unit the API does not name).
  The install's `routine_id` and the install time are kept on the build's record, so the outcome is found by routine
  in the month it was installed (UTC).
- **Errors in words.** `BuildCopy.sentence(for: APIError)` gives every `APIError` one plain sentence; a
  `policy_denied` shows the server's message as given; nothing shows a request id or a hash.

## Red tests (write these first, run them, see them fail)
Folder `apps/mac/Tests/OffloadMacTests/M313/`, Swift Testing, every test `@Test("TAG: ...")` inside
`@Suite struct M313` (tests in extensions of `M313` across files). Build JSON fixtures copied from the build-loop
port's `buildView` shape; fake `BuildsClient`, signer and clock.

| Tag | Tests (short) |
|---|---|
| LIST | builds started on this Mac newest first with name and state; a 404 build shows the gone line and can be removed; the store round-trips |
| STEPS | each stage name and state maps to the right row; row 1 shows the brief fingerprint; "2 of 3 attempts passing"; "1 failed · builder is fixing it"; an unknown stage is listed, not dropped |
| ATTEMPTS | one row per attempt by ordinal; outcome dots; frozen and held-out marks from `frozen_pass`, `held_out_pass` and `check_groups`; spend per attempt |
| HEADLINE | every state's headline, the server note under it, unknown state shown raw, dot colours |
| HELDOUT | passed, failed and not run from the winner, else the latest attempt |
| BUDGET | "6m 12s · $0.84 of $4.00" from a fixture; elapsed to now while running; half-up cents; amber at the cap |
| PLAN | answer build then poll the opportunity; designing and needs-connection lines; the fix's plan with the estimate labelled estimated and the cap; the 10-minute limit line |
| OKBUILD | posts exactly the four hashes read and `cap_usd` 4, signed; 202 records and selects the build; 403 `hash_mismatch` re-reads the fix and needs a new press; 409 `already_running`; `policy_denied` message; nothing posted without the press; no signer sends nothing |
| INSTALL | disabled until the definition was read; posts the build's two hashes and the definition's hash, signed; 201 shows the version; 403 re-reads both; 409 refreshes; not offered unless `ready` and not deployed |
| SAVING | estimate line before install; pending, measured and unmeasured lines after install from outcome Figures; a 404 outcome route line |
| POLL | polls every 2 s while live and stops at each end state; stops when the screen goes away; backs off on errors up to 60 s |
| SAMPLE | `.local` shows only the sample with the label first; the timeline state at ticks 0, 14, 40 (one failed), 80 and 92; Reduce Motion shows tick 92; Install disabled with its line; the sample is never stored or shown without the label; Replay restarts |
| HANDOFF | `.opportunity` starts the plan step; `.localRepeat` opens the sample with the repeat's name; the pending request is consumed once |
| STATES | no builds line; offline line; each `APIError` sentence |
| FIGURES | every number in `BuildDetail` comes from the build, fix or outcome fields or the labelled sample fixture |
| COPY | strings have no em dash, banned word or ADR 0016 term; captions lowercase with `·` items as separate items |
| CANCEL | Cancel build offered only while live, nothing posted otherwise; the returned build replaces the one shown; an error becomes a notice; `POST /v1/builds/{id}/cancel` unsigned with no body (added by review 2) |

## Out of scope
The builder, approvals and outcomes on the server (`services/**`); the SSE stream, cancel and retry buttons beyond
`cancel` on a live build; the receipt view; routines after install (M2 and M6 screens); pseudonym match "is this the
sheet?" (m5-06); any change to m3-10's folders.

## Verify
`bash slices/m3-13-mac-build-progress/verify.sh`. On Linux it checks scope and prints
`m3-13-mac-build-progress: SKIPPED (needs macOS)`; with `REQUIRE_MAC=1` (CI `mac` job) a skip fails.

## Test plan (owner, on the m3-09 test build)
1. In Local mode, open **Builds**: one row, "Sample build"; the label "Sample data: cloud not connected" is at the top
   of the detail and stays there. The sample plays once: a worker fails one check, is fixed, and every step turns
   green; **Install** stays disabled with "Installing needs the cloud." Press **Replay**.
2. (Needs m3-11 or m3-12 on the same build.) From Today, press **OK, build** on the card: Builds opens with "Building "<repeat>" needs the cloud…" and the
   labelled sample. Nothing new appears in the list.
3. Turn on Reduce Motion: the sample shows its final state at once.
4. With a cloud backend configured (when sign-in and enrollment exist): press OK, build on a suggested fix, read the
   plan and its estimate, press **OK, build**; the build appears in the list and its steps move every 2 s; when it is
   ready, **See what changed** lists what it will do and **Install** posts the approval once.

## Scope changes
- ROADMAP puts Build progress on the Mac in m5-06 (M5); the owner asked for it in the test build now. The Mac screen
  only; m5-06 keeps pseudonym match.
- **API gaps** (for the API owners; `docs/API.md` and `services/**` are not edited here): there is no
  `GET /v1/builds` list route, so the Mac lists the builds it started; there is no approval-request resource (an
  approval is the exact-hash POST, as API.md says); the `Opportunity` shape does not name its fix id yet, so the plan
  step reads `fix_id` when present and otherwise waits; the build-loop port implements only build-approvals,
  `GET /v1/builds/{id}` and deploy, so definition, cancel and outcomes return 404 until built; timestamps arrive in
  UTC `Z` form and are shown in the person's time zone.
- **Mockup divergence**: real builds show one row per attempt with frozen and held-out results; the 8 named workers
  with a box per check are in the sample only, because the API reports `check_groups` per attempt, not single checks.
- **`install` renamed `installState`**: the model's property and its `install()` method cannot share a name in Swift
  (a redeclaration), so the property is `installState`; the red tests were written against the SPEC's name and were
  changed with this note.
- **Implementation notes and small divergences** (m3-13 author):
  - No third-party code was ported. The sample's timeline (`SampleTimeline.state(at:)`) is the owner's mockup
    (`source.canvas.tsx`, "4. Build progress") ported tick for tick, with one change: a worker shows as waiting until
    its start tick (the mockup's failing worker showed as running from tick 0). Clicky and the old Offload repo have no
    build progress screen to pull from; m3-10's `BuildsClient`, `RequestSigner`, `RecordingTransport` and
    `SampleDataLabel` are used as they are.
  - The build loop's own stage names (`teeth_gate`, `worker`, `verification`, `fan_out`, `winner`, and `end` or
    `recovered` when a build ends outside a stage) were read from the port's `loop.ts`. In the loop a first worker
    that fails marks `verification` failed and then runs `fan_out`, so a failed stage of a build that is still live is
    drawn as waiting (it is being fixed), and failed only once the build has ended. `end` and `recovered` are unknown
    names here and are listed under row 3.
  - Dots: `cancelled` and an unknown state are amber (needs you), as nothing was installed; a gone build's row is amber.
  - The plan panel has **Not now** (closes the plan, nothing posted). In `.cloud`, a `.localRepeat` hand-off says
    "“<name>” was counted on this Mac. Build it from a suggestion in Today once Offload has seen it." and shows no
    sample (sample data exists only in `.local`).
  - The start time in the list ("started 22 Nov, 11:50") is a date in the person's time zone, not a caption: its
    month keeps its capital.
  - The meter's elapsed time is recomputed on each poll (every 2 s while live), not every second.
  - Views (`BuildProgressViews.swift`, `BuildProgressScreen.swift`) are not unit tested; everything they show comes
    from the tested model and pure types.
- **Review 1** (an independent Opus read; nothing compiled on Linux): fixed a test that would not compile
  (`figuresSample` built its allowed numbers as an array); Remove from list moved out of the row's button so a click
  and VoiceOver reach it; the VoiceOver dot and step words moved into `BuildCopy`; a later hand-off cancels an earlier
  one before it answers anything; only an offline read says "Can't reach Offload. Retrying." (other failures in their
  own words); `needs_connection` without apps keeps designing; Return no longer presses OK, build (an approval needs
  a deliberate click). Left for the owner: the Contract's "the Mac formats them only" for hs-1 numbers versus the
  measured line computed as `ratio` × `estimated_minutes_per_week` ÷ 60 (Design note), until the outcome carries a
  measured-per-week Figure.
- **Review 2** (`logs/m3-13-mac-build-progress.review1.md`, verdict CHANGES; every finding taken):
  1. Tests now cover cancel (new tag `CANCEL`: offered only while live, the returned build replaces the one shown, an
     error becomes a notice, the unsigned route), choosing another build (clears the definition read; refuses ids not
     on this Mac), **Not now**, a failed answer, no fix to build and a definition the server does not have.
  2. Disabled actions are drawn faded (`ActionLook`, 0.4) because m3-04's button styles do not read `isEnabled`; the
     sample's Install is faded with "Installing needs the cloud." under it, and in `.cloud` "Read what it will do
     first." is on screen until See what changed was read.
  3. A definition read, an install or their errors are kept only for the build still chosen; an install that ends
     after another build was chosen is still written to its own record.
  4. The poll and the plan poll say "Retrying" only when offline, other failures in their own words; a signed-out
     answer (401) stops polling.
  5. Coming back to Builds resumes the plan poll; leaving while the answer is on its way is not an error (the plan
     waits on the opportunity, which tells whether the answer arrived); an earlier plan's failure no longer stops a
     later plan.
  6. Hours are rounded half to even to one decimal, as hs-1 displays them (ADR 0022). **Divergence kept for the
     owner:** the measured hours are still `ratio` × `estimated_minutes_per_week` ÷ 60 computed on the Mac, against the
     Contract's "the Mac formats them only", until the outcome carries a measured-per-week Figure (an API gap for the
     outcomes owners).
  7. The builds started on this Mac live in `UserDefaults` under `ai.offload.builds.startedOnThisMac`: build, fix and
     routine ids, the suggestion's name as shown, start and install times. **For the SECURITY_PRIVACY owners**
     (that file is outside this slice): add the key to the list of what the Mac keeps in `UserDefaults`, and include
     it in the Mac's forget and sign-out flows when they land; a forget path is needed because the name comes from
     the person's activity. Until then **Remove from list** removes a gone build's entry. The glossary row is
     corrected (it said "ids and dates only" while listing the name).
  8. Known providers keep their brand names ("GitHub", "HubSpot", "Google Sheets"); others are title-cased. The
     `copyLines` and `planNeedsConnection` tests had locked in "Github" and were corrected with this note.
  9. The plan panel shows "fingerprint 7c41e2" of the brief whose hashes OK, build posts, and the new one after a
     `hash_mismatch` re-read (`PlanSummary.fingerprint`; the `planSummary` test's expected value gained it).
  10. An ended build without `ended_at` stops at its last stage's end (or stands still), never counting on to now.
  11. Test plan step 2 needs m3-11 (Today) or m3-12 (Weekly review) to call `NavigationModel.startBuild`; nothing on
      this branch does yet. The hand-off is covered by the HANDOFF tests, and Builds opens the labelled sample from
      the sidebar.
- `BASE` is set after m3-10 is `done`, so m3-10's placeholder commit in `BuildProgress/` is not counted against this
  slice's `owns`.
