---
id: m3-11-mac-today-live
title: Today on the Mac wired to real data (local insights on this Mac, the brain's records and opportunities in the cloud), with things you repeat, one suggested fix, the hand-off to Build progress and the menu bar summary
milestone: M3
status: ready
depends_on: [m3-10-mac-recordings-analysis]
parallel_safe: true
human_gated: true
model_tier: sonnet
size: M
parallel_group: M3-E
owns: [apps/mac/Sources/OffloadMac/TodayLive/**, apps/mac/Tests/OffloadMacTests/M311/**]
verify: bash slices/m3-11-mac-today-live/verify.sh
min_tests: 55
paths_in_scope: [apps/mac/Sources/OffloadMac/TodayLive/**, apps/mac/Sources/OffloadMacApp/**, apps/mac/Tests/OffloadMacTests/M311/**, apps/mac/README.md, docs/GLOSSARY.md, slices/m3-11-mac-today-live/**]
paths_out_of_scope: [ee/**, services/**, packages/**, apps/web/**, docs/adr/**, .github/**, NOTICE, apps/mac/Package.swift, apps/mac/Packaging/**, apps/mac/TestBuild/**, apps/mac/Sources/OffloadMac/OffloadMac.swift, apps/mac/Sources/OffloadMac/Updates/**, apps/mac/Sources/OffloadMac/SelfCheck/**, apps/mac/Sources/OffloadMac/Version/**, apps/mac/Sources/OffloadObserver/**, apps/mac/Sources/OffloadMasker/**, apps/mac/Sources/OffloadStore/**, apps/mac/Sources/OffloadUploader/**, apps/mac/Sources/OffloadImport/**, apps/mac/Sources/OffloadMac/Recordings/**, apps/mac/Sources/OffloadMac/Today/**, apps/mac/Sources/OffloadMac/Onboarding/**, apps/mac/Sources/OffloadMac/Permissions/**, apps/mac/Sources/OffloadMac/LocalNow/**, apps/mac/Sources/OffloadMac/NeverWatch/**, apps/mac/Sources/OffloadMac/Design/**, apps/mac/Sources/OffloadMac/Shell/**, apps/mac/Sources/OffloadMac/Analysis/**, apps/mac/Sources/OffloadMac/OnDevice/**, apps/mac/Sources/OffloadMac/Backend/**, apps/mac/Sources/OffloadMac/Navigation/**, apps/mac/Sources/OffloadMac/WeeklyReview/**, apps/mac/Sources/OffloadMac/BuildProgress/**, apps/mac/Tests/OffloadMacTests/SmokeTests.swift, apps/mac/Tests/OffloadMacTests/M304/**, apps/mac/Tests/OffloadMacTests/M305/**, apps/mac/Tests/OffloadMacTests/M309/**, apps/mac/Tests/OffloadMacTests/M310/**, apps/mac/Tests/OffloadMacTests/M312/**, apps/mac/Tests/OffloadMacTests/M313/**]
red_tests: [HEADER, DAY, GRID, DID, REPEATS, HOW, FIX, ANSWER, HANDOFF, CLOUD, STATES, BANNERS, MENU, KEYS, FIGURES, COPY]
---

# m3-11-mac-today-live

## Summary
The mockup's **Daily / Today** screen (`Daily`, mockups `source.canvas.tsx` lines 479 to 626) on the Mac, wired to
real data. In `.local` backend mode it reads m3-10's local insights (recordings imported and analysed on this Mac,
and live capture once m3-02 fills the local buffer); in `.cloud` mode it reads the brain's day and week records and
the open opportunities ([API.md "Today, records and review"](../../docs/API.md#today-records-and-review-core-m5-unless-noted),
[API.md "Opportunities, fixes and builds"](../../docs/API.md#opportunities-fixes-and-builds-core)). It shows the
header, the day grid, "What you did", "Keeps coming back this week" (things you repeat with minutes per week and how
each number was counted), one suggested fix at a time with **OK, build** handed to m3-13's Build progress, the empty,
importing and error states, and a one-line summary in the menu bar item. It replaces m3-10's `TodayLiveScreen`
placeholder and keeps m3-04's banners. This is ROADMAP m5-05's Mac screen brought forward for the test build (see
Scope changes). `human_gated: true`: the owner checks it against his own imported recordings.

## Contract
- **No new dependency, no Package.swift change.** Only files under `TodayLive/` plus one additive edit to
  `OffloadMacApp/OffloadApp.swift` (the menu bar line).
- **`TodayLive/`**:
  - `TodayLiveScreen(app:)` (the m3-10 entry point, same initialiser) draws `TodayLiveView` over
    `TodayLiveModel`.
  - `TodayLiveModel` (@MainActor): `state` (`.empty`, `.importing(file:of:)`, `.ready(TodayContent)`,
    `.notRecorded(day)`, `.failed(TodayError)`), `day` (shown day), `days` (days with data), `previousDay()`,
    `nextDay()`, `refresh()`, `selectOption(_:)`, `okBuild()`, `notNow()`, `leaveAlone()`, `toggleHow(_:)`. It reads
    `app.backends`, `app.insights`, `app.recordings` and `app.navigation` (m3-10) and `app.today` (m3-04's banners).
  - `TodayContent` (pure, Equatable): `title` ("Today · Thu, Nov 12", or "Thu, Nov 5" for an earlier day),
    `headline`, `subtitleItems`, `grid: DayGrid?`, `kinds: [KindRow]` (cloud), `did: [DidRow]`, `repeats:
    [RepeatRow]`, `fix: FixCard?`, `provenance` (m3-10's `DataProvenance`).
  - `TodayContent.local(snapshot:day:rhythm:timeZone:answers:)` and `TodayContent.cloud(day:week:opportunities:)`:
    pure builders, every number from a `Figure` (m3-10).
  - `DayGrid`: 15-minute cells from the person's rhythm start to end (m3-04 `Rhythm`, default 9:00 to 18:00 = 36
    cells), widened to whole hours to cover any activity outside; rows are the day's top 5 apps (local; a sixth row
    "Other"); a cell belongs to the row with the most active seconds in it, when that is at least 60 s; the "Switch
    bursts" row marks cells with 4 or more app switches; the hour axis reads "9a", "10a", … "12p", "1p", …
    Colours in row order: blue, cyan, amber, purple `#b48cff`, green (the mockup's order, from `Tokens`).
  - `TodayMenuSummary.line(snapshot:day:)` → "today · 3 h 10 m · mostly Xcode" (local) or from the cloud day record;
    nil when nothing was counted today, and the menu shows no line.
  - `TodayCopy`: every string of the screen.
- **Hook** (`OffloadMacApp/OffloadApp.swift`, additive): `MenuBarOpener` shows the summary line above m3-04's
  menu content when it is not nil.
- **Data, `.local`** (m3-10 `InsightsSnapshot`, `LocalAnswerStore`):
  - Shown day: today when anything was counted today, else the latest day with data (imports are of past days);
    `previousDay`/`nextDay` step through days with data.
  - Header: "7 h 40 m of work." plus "Most of it in Xcode." only when the top app holds 40% or more of the active
    time; subtitle items "longest focus 1 h 30 m", "38 switches an hour".
  - "What you did": the day's sessions of 10 minutes or more: start time, a name built from the session's top app
    and top host ("Xcode and github.com"), duration. No text is ever used for a name.
  - "Keeps coming back this week": the top 5 repeats in the ISO week of the shown day: name, a Mon to Sun strip of
    occurrences per day (bar full opacity above 1), and "6× · 3.1 h" (occurrences and hours this week). Tapping the
    count opens "how: 6 times × 31 min median = 3.1 h · Mon–Thu" from the Figure's arithmetic.
  - Suggested fix (one at a time, the top-ranked repeat not declined): "You've done Xcode, then github.com, then
    Slack 6 times this week." with the status line "Top repeat · counted on this Mac". On the Mac there is no fix
    designer, so there are no options: buttons **OK, build** (hands `.localRepeat` to Build progress), **Not now** and
    **Leave it alone** (answers `not_now` and `leave_alone` through `LocalAnswerStore`, keyed by the repeat's
    `k_` key and ISO week; the card moves to the next repeat).
- **Data, `.cloud`** (m3-10 `BrainClient`, `BuildsClient`):
  - `GET /v1/records/days/{date}` → header "7 h 40 m of work." from `totals.active_minutes`, subtitle from
    `totals.focus_blocks` and `totals.switches_per_active_hour`; "What you did" from `by_task` (name and minutes);
    "Time by kind" rows from `by_kind` instead of the grid (the cell grid comes from `GET /v1/today`, not built yet).
  - `GET /v1/records/weeks/{iso_week}` → "Keeps coming back this week" from `tasks` with `instances` of 2 or more,
    by minutes: "6× · 3.1 h" from `instances` and `minutes`; how lines from their Figures' `arithmetic`.
  - `GET /v1/opportunities?state=open` → the first by rank is the card: status line "Suggested fix · ranked first for
    <goal>" when it names a goal, title from the opportunity, up to 3 numbered `options` (title, detail, "saves 1.4
    h/wk" from the option's saving Figure, "recommended" on the recommended one). **OK, build** hands
    `.opportunity(id:optionID:)` to Build progress; **Not now** and **Leave it alone** post
    `POST /v1/opportunities/{id}/answer` with `not_now` or `leave_alone`; picking "Leave it alone" as an option turns
    the primary button into "Leave it alone", as the mockup.
  - A 404 for the day is `.notRecorded` ("Nothing recorded for this day yet."), not an error.

## Design note
- **Layout** follows the mockup and its rules: one fix at a time, every number opens to how it was counted (quiet by
  default, one click away), no eyebrow labels, no coloured headline word, lowercase captions with `·` items, tabular
  numbers, cells pop in on a stagger and Reduce Motion shows the final state, blue is working, amber needs you, green
  is done. The window keeps m3-04's paper canvas with the dark chrome card for the content, as the mockups' `Stage`.
- **States**: *empty* (`.local`, nothing counted): "Nothing counted yet." and "Import a recordings folder, or keep
  working with capture on." with **Choose recordings** (selects m3-10's Recordings screen); *importing* (an import
  is reading or insights are analysing): the line "reading file 3 of 12 · Today updates when it's done" above
  whatever was already counted; *failed* (`.cloud` error): one sentence per `APIError` code (`unauthenticated` and
  `token_expired`: "Sign in again to see Today."; offline: "Can't reach Offload. Showing nothing rather than old
  numbers."; others: "Today could not load (code).") with **Try again**. No state ever shows a number that was not
  counted.
- **Banners**: m3-04's `TodayModel.banners` (finish setting up, Local mode, product mode) sit above the content with
  m3-04's `tapBanner` and `dismissBanner`, unchanged.
- **Keyboard** (mockup hint "1 / 2 / 3 to pick · ↵ to build"): 1, 2, 3 pick an option, Return presses the primary
  button, both only while the card has focus.
- **Provenance**: `.local` shows m3-10's caption "counted on this Mac"; Today never shows sample data (in `.local`
  without data it shows the empty state).
- **Refresh**: the model refreshes when the screen appears, when the insights snapshot changes and every 60 s while
  visible (live capture); `.cloud` reads are not repeated more than once a minute.

## Red tests (write these first, run them, see them fail)
Folder `apps/mac/Tests/OffloadMacTests/M311/`, Swift Testing, every test `@Test("TAG: ...")` inside
`@Suite struct M311` (tests in extensions of `M311` across files). Fixtures are synthetic insights snapshots and
brain-port JSON.

| Tag | Tests (short) |
|---|---|
| HEADER | "7 h 40 m of work." from a fixture; "Most of it in Xcode." only at 40% or more; subtitle items longest focus and switches an hour; zero active time gives the empty state, not "0 h" |
| DAY | today when counted today, else the latest day with data; previous and next step through days with data only; title "Today · Thu, Nov 12" vs "Thu, Nov 5" |
| GRID | 36 cells for 9:00 to 18:00; widened to whole hours for activity at 7:40; a cell goes to the row with most seconds, only at 60 s or more; top 5 rows plus Other; switch bursts at 4 switches; hour axis labels; row colours in mockup order |
| DID | sessions of 10 minutes or more with start time and duration; names from app and host only; a session with an excluded app shows "Never watch app" |
| REPEATS | top 5 of the shown week; Mon to Sun strip counts per day; "6× · 3.1 h" from the Figures; a repeat declined on this Mac is not listed |
| HOW | tapping the count shows the arithmetic line with the weekdays; a second tap hides it; every repeat row has one |
| FIX | local card is the top undeclined repeat with no options; cloud card shows up to 3 options with savings and recommended; picking "Leave it alone" changes the primary label; no card when nothing qualifies |
| ANSWER | local Not now writes `not_now` for the repeat's key and week and the card moves on; Leave it alone writes `leave_alone`; cloud posts `POST /v1/opportunities/{id}/answer` with the exact body |
| HANDOFF | OK, build in `.local` calls `navigation.startBuild(.localRepeat(...))` with the key, name and minutes per week; in `.cloud` `.opportunity(id:optionID:)` with the picked option; the Builds screen is selected |
| CLOUD | day and week records and opportunities map to header, kinds, did, repeats and the card; a 404 day is `.notRecorded`; no request is made in `.local` |
| STATES | empty with Choose recordings selecting the Recordings screen; importing line while m3-05's phase is reading; failed sentences per error code with Try again; nothing counted shows no number |
| BANNERS | m3-04's banners appear above the content and their actions reach `AppModel` |
| MENU | "today · 3 h 10 m · mostly Xcode" from a fixture; nil when nothing counted today; the cloud line from the day record |
| KEYS | 1, 2, 3 pick options and Return presses the primary button |
| FIGURES | every number in `TodayContent` traces to a Figure with arithmetic and evidence (walks the content) |
| COPY | strings have no em dash, banned word or ADR 0016 term; captions lowercase with `·` items as separate items |

## Out of scope
The day grid in `.cloud` mode (needs `GET /v1/today`, m5-05's API half); "how it was counted" evidence rows
(`GET /v1/figures/{id}/evidence`); the fix designer and options on the Mac in `.local` mode; the Build progress screen
(m3-13); any change to m3-04's `Today/` or m3-10's folders.

## Verify
`bash slices/m3-11-mac-today-live/verify.sh`. On Linux it checks scope and prints
`m3-11-mac-today-live: SKIPPED (needs macOS)`; with `REQUIRE_MAC=1` (CI `mac` job) a skip fails.

## Test plan (owner, on the m3-09 test build)
1. With recordings imported (m3-10's test plan), open **Today**: the header, grid and "What you did" match what you
   remember of that day; the title names the day shown when it is not today. Step back and forth between days.
2. In "Keeps coming back this week", click a count: the line says how it was counted. Compare one against the
   recordings (times and days).
3. On the card, press **Not now**: the next repeat takes its place; relaunch, it stays away. Press **OK, build**:
   Build progress opens (in Local mode a clearly labelled sample).
4. Before any import (or after Remove imported data): Today shows "Nothing counted yet." and **Choose recordings**
   opens the Recordings screen. Start an import: the importing line shows, and Today fills in when it is done.
5. The menu bar item shows "today · … · mostly …" on a day with data and no line on a day without.
6. Turn on Reduce Motion: the grid appears at once.

## Scope changes
- ROADMAP puts Today's Mac screen in m5-05 (M5) with its API; the owner asked for it in the test build now. This
  slice is the Mac screen only, `milestone: M3` with the wave; m5-05 keeps `GET /v1/today` and the evidence route.
- Divergences from the mockup, honest by design: in `.local` the grid rows are apps, not kinds of work, and session
  names are app and host names (no model names work on the Mac, ADR 0003 and ADR 0005); the card has no options
  because options come from the fix designer in the cloud; in `.cloud` the grid is replaced by "Time by kind" until
  `GET /v1/today` exists.
- `apps/mac/Sources/OffloadMacApp/**` is shared (m3-04, m3-05, m3-09, m3-10 edit it); this slice adds one view line.
- `BASE` is set to the commit this slice starts from, after m3-10 is `done`, so m3-10's placeholder commit in
  `TodayLive/` is not counted against this slice's `owns`.
