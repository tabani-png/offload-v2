---
id: m3-11-mac-today-live
title: Today on the Mac wired to real data (local insights on this Mac, the brain's records and opportunities in the cloud), with things you repeat, one suggested fix, the hand-off to Build progress and the menu bar summary
milestone: M3
status: in_progress
depends_on: [m3-10-mac-recordings-analysis]
parallel_safe: true
human_gated: true
model_tier: sonnet
size: M
parallel_group: M3-E
owns: [apps/mac/Sources/OffloadMac/TodayLive/**, apps/mac/Tests/OffloadMacTests/M311/**]
verify: bash slices/m3-11-mac-today-live/verify.sh
min_tests: 55
paths_in_scope: [apps/mac/Sources/OffloadMac/TodayLive/**, apps/mac/Sources/OffloadMac/App/OffloadApp.swift, apps/mac/Sources/OffloadMacApp/**, apps/mac/Tests/OffloadMacTests/M311/**, apps/mac/README.md, docs/GLOSSARY.md, slices/m3-11-mac-today-live/**]
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
  `OffloadMac/App/OffloadApp.swift` (the menu bar line; the app lived in `OffloadMacApp/` before m3-10's rebase).
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
- **Hook** (`OffloadMac/App/OffloadApp.swift`, additive): `MenuBarOpener` shows the summary line above m3-04's
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

### Implementation notes (build, 2026-11-22)
- **Files** (`TodayLive/`): `TodayCopy.swift` (every string), `TodayContent.swift` (the pure content types and the
  `.local` and `.cloud` builders), `DayGrid.swift` (the cell grid), `TodayMenuSummary.swift`, `TodayLiveModel.swift`
  (@MainActor: state, day stepping, answers, hand-off, keys, the 60 s refresh rule), `TodayLiveView.swift` (views
  only) and `TodayLiveScreen.swift` (the m3-10 entry point, same initialiser).
- **One model per app**: `TodayLiveModel.shared(for: app)` keeps one model per `AppModel`, so the day picked and the
  open "how" lines survive a trip to another screen, and the menu bar line reads the same model. The model listens to
  `insights.$snapshot`, `insights.$isAnalysing` and `recordings.$phase` and uses the values they publish (a
  `@Published` sink runs before the property changes).
- **Builders take what they need, explicitly**: `TodayContent.local(snapshot:day:rhythm:timeZone:answers:now:)` and
  `TodayContent.cloud(day:week:opportunities:today:timeZone:)` (`now` and `today` name the day shown as "Today"; a pure
  builder never reads the clock). Both return nil when nothing was counted for the day, which the model shows as the
  empty state (`.local`) or `.notRecorded` (`.cloud`); a zero is never drawn.
- **A repeat this week** (local): the pattern's occurrences in the ISO week of the shown day. `times` is a count Figure
  ("Mon 1 + Tue 1 + Wed 2 + Thu 2 = 6 times"), `minutes` the sum of those occurrences ("6 times · 31 min median · 186
  min = 3.1 h"), so "6× · 3.1 h" and the how line read the same arithmetic. The mockup's "6 times × 31 min median"
  multiplies a median, which would disagree with the counted sum whenever the occurrences differ in length; the sum is
  shown and the median stays as an item (see Scope changes). The weekdays item is "Mon–Thu" for a run of days, else
  the days listed.
- **Declined**: a repeat is left out of the list and the card when the snapshot ranks it declined or when the answers
  on this Mac decline it now (`RankingAdjustments(answers:).declinePenalty == 0`), so Not now moves the card at once,
  before the store re-ranks (`insights.reload()` runs after each answer).
- **Session names and times** (local): "Xcode and github.com" from the session's top app and top host; start times
  in the hour axis's style ("9:00a", "1:00p": the mockup's "1:00" would read the same as 1:00 at night); durations
  from the session's active seconds ("1 h 05 m", padded as the mockup's mono column).
- **Cloud card**: open opportunities by rank (no rank last, then id). Options are the opportunity's options that are
  not `leave_alone`, by `option_no`, at most 3, then "Leave it alone" (the server's `leave_alone` option when it sends
  one, else a choice of its own). The recommended option is picked at first. Keys 1 to the number of choices pick;
  Return presses the primary button. Picking "Leave it alone" makes the primary button "Leave it alone", which posts
  `leave_alone`. The keys hint lists the numbers there are ("1 / 2 / 3 / 4 to pick · ↵ to build").
- **Cloud days**: `previousDay`/`nextDay` step one calendar day, never past today; a 404 shows "Nothing recorded for
  this day yet." Left on today, Today follows the calendar past midnight; a day the person stepped to stays. Without a
  brain client (a hand-built `Backends` only), `.cloud` fails with "Sign in again to see Today." (review 2). The week record's 404 leaves the repeats empty; any other error fails the screen with one sentence.
- **Importing**: `.importing(file:of:)` while m3-05's phase is reading; `of == 0` while local insights recount the
  days of an import that just finished, or while they count with nothing shown yet ("counting on this Mac · Today
  updates when it's done"). Live capture's minute-by-minute recount of today shows no line (review 1). Whatever was
  already counted stays below the line.
- **Menu bar line**: `TodayMenuLine(app:)` (a view in `TodayLive/`) draws the model's `menuLine`; `OffloadApp.swift`
  gains that one line above m3-04's menu content. The shared model keeps it true on its own clock, `menuTick()`, at
  launch, every minute for the app's life and on `NSCalendarDayChanged` (the menu bar's `.menu` style does not re-run
  a view's `.task`): a new day is published at once, so a line for yesterday goes away; in `.cloud` it reads today's
  day record (at most once a minute, at once on a new day; a failed read clears the line, as the screen shows nothing
  rather than old numbers) and a cached record of another day is never shown as today's; in `.local` it recounts
  today only while live capture runs (review 2).
- **How it was counted** (review 1): the headline, the subtitle items, each "What you did" duration, each repeat's
  count, each kind's minutes and the card's count open to "how: …" on a click (a cloud card's count is the week
  task's `instances` when the opportunity names that task; without it the title is plain text, review 2) (and carry it as a tooltip and an
  accessibility hint); an option's saving shows its arithmetic under the option once it is picked. A cloud repeat's
  how line has the instances' and the minutes' arithmetic.
- **Keys** (review 1): the fix card takes focus by default when Today appears, when it is clicked and when an option is
  picked; a key that reaches the card's handler means focus is on the card or inside it.
- **Colours**: text on the chrome uses `chromeMute` or brighter, never `chromeFaint` (decoration only). Cloud "Time by
  kind" gives each of the brain's `WORK_KINDS` one colour (code blue, docs cyan, email amber, meeting purple, browse
  green, chat and sheet two more; unknown kinds and `other` take Other's), so a kind keeps its colour from day to day.

### Review 1 (2026-11-22, logs/m3-11-mac-today-live.review1.md)
Red tests first (`M311Review1Tests.swift`), then: (1, major) no text in `chromeFaint`; (2) the card takes focus so the
keys work, Test plan step 7; (3) the card's count, option savings and cloud repeat counts open to how they were
counted; (4) no counting line for live capture's recount; (5) the menu line reads today itself in `.cloud` and is
cleared on a failed read; (6) tests for both answer failures, OK, build with Leave it alone picked, a stale cloud read
and the capture tick; (7) one colour per kind of work; (8) this SPEC's paths and `BASE` bullets.

### Review 2 (2026-11-22, logs/m3-11-mac-today-live.review2.md)
Red tests first (`M311Review2Tests.swift`), then: (1, major) the menu line never shows another day's record as
today and is kept true by the model's `menuTick` (minute clock and day change), and Today in `.cloud` follows the
calendar past midnight unless a day was picked; (2) the cloud card's count opens to the week task's instances, else
the title is plain text; (3) `.cloud` without a brain client fails with Sign in again.

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
7. In `.cloud` (or with the card on screen in `.local`): press 1, 2, 3 to pick an option and Return to press the
   primary button; click the card first if focus is elsewhere. Click the card's title: the line says how its count
   was counted.

## Scope changes
- m3-10's 2026-11-22 rebase moved the app from `OffloadMacApp/OffloadApp.swift` to
  `OffloadMac/App/OffloadApp.swift`; `paths_in_scope` adds that one file for the menu bar line (the Contract's hook).
- The how line shows the counted sum of the week's occurrences ("6 times · 31 min median · 186 min = 3.1 h"), not the
  mockup's "6 times × 31 min median = 3.1 h": times × median is an estimate that differs from the counted minutes when
  occurrences differ in length (ADR 0003). The card's title on the Mac says "You've done X 6 times this week." from the
  same count.
- `TodayContent.local` takes `now:` and `TodayContent.cloud` takes `today:` and `timeZone:` (the title says "Today"
  only for today's date); the Contract's shorter signatures had no way to know which day is today.
- Reference repos: no code was ported. The layout, timings (cells pop in at 14 ms a cell and 40 ms a row, 150 ms
  after the screen appears) and copy follow the owner-approved mockup's `Daily` component (`source.canvas.tsx` lines
  479 to 626); the data path is m3-10's. Nothing needs a NOTICE line.
- `BASE` is m3-10's last commit on this stack (`e80962a`; it was `d3d6651` until m3-10 was rebased onto the
  rewritten `w1/h-shell-onboarding`, which left `d3d6651` outside this branch's history), taken while m3-10 is still
  `in_progress` (its review 3 is done); this slice's commits are the only ones counted by the scope check (subject
  prefix), so m3-10's placeholder commit in `TodayLive/` is not counted against this slice's `owns`.
- ROADMAP puts Today's Mac screen in m5-05 (M5) with its API; the owner asked for it in the test build now. This
  slice is the Mac screen only, `milestone: M3` with the wave; m5-05 keeps `GET /v1/today` and the evidence route.
- Divergences from the mockup, honest by design: in `.local` the grid rows are apps, not kinds of work, and session
  names are app and host names (no model names work on the Mac, ADR 0003 and ADR 0005); the card has no options
  because options come from the fix designer in the cloud; in `.cloud` the grid is replaced by "Time by kind" until
  `GET /v1/today` exists.
- `apps/mac/Sources/OffloadMac/App/OffloadApp.swift` is shared (m3-04, m3-05, m3-09, m3-10 edit it); this slice adds
  one view line.
