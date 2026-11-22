---
id: m3-04-mac-onboarding
title: Mac app shell (menu bar item, main window, Today empty state) and the onboarding flow with live permission ticks, the local now summary, Never watch and product modes
milestone: M3
status: in_progress
depends_on: [m3-02-mac-capture-upload]
parallel_safe: true
human_gated: true
model_tier: opus
size: L
parallel_group: M3-C
owns: [apps/mac/Sources/OffloadMac/Shell/Launch.swift, apps/mac/Sources/OffloadMac/Shell/AppMover.swift, apps/mac/Sources/OffloadMac/Shell/MenuBar.swift, apps/mac/Sources/OffloadMac/Shell/RootView.swift, apps/mac/Sources/OffloadMac/Shell/LiveServices.swift, apps/mac/Sources/OffloadMac/Onboarding/OnboardingFlow.swift, apps/mac/Sources/OffloadMac/Onboarding/OnboardingState.swift, apps/mac/Sources/OffloadMac/Onboarding/OnboardingStore.swift, apps/mac/Sources/OffloadMac/Onboarding/OnboardingCopy.swift, apps/mac/Sources/OffloadMac/Onboarding/Profile.swift, apps/mac/Sources/OffloadMac/Permissions/**, apps/mac/Sources/OffloadMac/LocalNow/**, apps/mac/Sources/OffloadMac/NeverWatch/**, apps/mac/Sources/OffloadMac/Today/**, apps/mac/Sources/OffloadMac/Design/**, apps/mac/Tests/OffloadMacTests/M304/**]
verify: bash slices/m3-04-mac-onboarding/verify.sh
min_tests: 80
paths_in_scope: [apps/mac/Sources/OffloadMac/Shell/**, apps/mac/Sources/OffloadMac/Onboarding/**, apps/mac/Sources/OffloadMac/Permissions/**, apps/mac/Sources/OffloadMac/LocalNow/**, apps/mac/Sources/OffloadMac/NeverWatch/**, apps/mac/Sources/OffloadMac/Today/**, apps/mac/Sources/OffloadMac/Design/**, apps/mac/Sources/OffloadMac/App/**, apps/mac/Tests/OffloadMacTests/M304/**, apps/mac/Package.swift, apps/mac/README.md, docs/GLOSSARY.md, docs/ONBOARDING.md, docs/SECURITY_PRIVACY.md, slices/m3-04-mac-onboarding/**]
paths_out_of_scope: [ee/**, services/**, packages/**, apps/web/**, docs/adr/**, .github/**, NOTICE, apps/mac/Packaging/**, apps/mac/Sources/OffloadMac/OffloadMac.swift, apps/mac/Sources/OffloadMac/Updates/**, apps/mac/Sources/OffloadMac/SelfCheck/**, apps/mac/Sources/OffloadObserver/**, apps/mac/Sources/OffloadMasker/**, apps/mac/Sources/OffloadStore/**, apps/mac/Sources/OffloadUploader/**, apps/mac/Tests/OffloadMacTests/SmokeTests.swift]
red_tests: [SHELL, ONBOARDING, MODE, REASK, PERMS, NOW, NEVERWATCH, COPY, TOKENS, TIME, META, TYPE, BUDDY]
---

# m3-04-mac-onboarding

## Summary
The first launchable Offload for the Mac ([M3](../../docs/ROADMAP.md#m3-capture-to-cloud), ROADMAP row m3-04): a
SwiftUI app with a menu bar item and a main window, the onboarding flow of [ONBOARDING.md](../../docs/ONBOARDING.md)
(screens 0 to 13, every skip path in section 10.2, the product modes of section 10.1, the re-ask limits of 10.3 and
the coming-back rows of section 11), and Today as an honest empty skeleton. It ports the Clicky permission gate and the
live permission ticks from PR #44, rewrites the old `GET /now` as the on-device local now summary (no model call, no
upload), and gives the m3-02 observer a "Never watch" exclusion source to read. Screens whose backend lands later
(sign-in M1-04, upload consent M3, profile M5, connections M2/M5, recordings m3-05) have their real copy and navigation
over injected service protocols, with fakes in tests and network-free stand-ins in the app.
`human_gated: true`: the permission grants and the Screen Recording relaunch need the owner on a real Mac with the
signed bundle (m3-03).

## Contract
- **Package.swift (additive)**: one executable product `Offload` and target `OffloadMacApp`
  (`Sources/OffloadMacApp`, depends on `OffloadMac`) holding only the `@main` SwiftUI `App`, the menu bar scene and
  the app delegate. All logic and views stay in the `OffloadMac` library so `swift test` reaches them. No new
  dependency. `OffloadMac.swift` (the m3-02/m3-03 TODO marker) and `SmokeTests.swift` are left as they are: m3-02's
  SPEC deletes them.
- **Launch** (`Shell/`): `LaunchOptions.parse(arguments:)` reads `--onboarding` and `--onboarding-screen <n>`;
  `LaunchRoute.decide` picks the move-to-Applications sheet (translocated or disk-image path), "Start fresh" (local
  buffer cannot be opened, row 11.6), onboarding at the saved screen (11.1, 11.8), screen 5 again for a new notice
  version (11.11), or Today.
- **Onboarding state machine** (`Onboarding/`): `OnboardingScreen` 0 to 13; `OnboardingFlow` (pure struct) with
  `OnboardingState` (Codable) persisted through `OnboardingStore` (`UserDefaultsOnboardingStore`, in-memory fake).
  Actions per screen; Back keeps typed text. Derived `ProductMode` (Full, Watching, Text only, Screen only, Connected
  apps only, Dormant, Local). `ReaskPolicy` for 10.3 limits.
- **Injected services** (protocols; app stand-ins make no network call and say so honestly):
  `AccountService` (screen 4, M1-04), `ConsentService` (`POST /v1/me/consents`, screen 5), `Uploader` (start only
  after **Start sending**), `CaptureControl` (observer start, m3-02), `ProfileService` (`PATCH /v1/profile`, M5),
  `ExclusionService` (`POST /v1/exclusions`), `ConnectionService` (`/v1/connections`, M2/M5), `LoginItemService`
  (`SMAppService`), `PermissionProbe` (TCC calls; tests use a fake so nothing touches TCC).
- **Permissions** (`Permissions/`): `ScreenPermissionGate` (ask once per launch, then the Privacy pane; a confirmed
  Screen Recording grant survives a `CGPreflightScreenCaptureAccess` false negative and is persisted),
  `PrivacyPane` (pane URLs and control names for macOS 14, 15, 26, root fallback with "Choose Screen Recording, then
  turn on Offload."), `PermissionTicker` (1.5 s polling, ticks only for changes seen while open, quit-and-reopen on a
  new Screen Recording grant), `PermissionsModel` (@MainActor, owns the poll task), `LivePermissionProbe` (AppKit,
  never used by tests). Input Monitoring is never requested.
- **Local now summary** (`LocalNow/`): `LocalEvent` (the old s34 day-file line shape: `id`, `ts` ms, `kind`, `app`,
  `appName`), `LocalNowSummary.compute(events:now:minutes:captureStartedAt:)`: top 3 apps by active minutes, switches
  inside the window, idle excluded (`idle_start` backdated 120 s), the line
  `"10 min · Cursor 6m · Google Chrome 3m · Slack 1m · 4 switches"`, a lowercase remark from the numbers, the headline
  with the real span. `LastTenMinutesState`: refresh every 5 s, pointer flies once at the first full minute,
  nothing-seen copy, after 2 minutes the "turn on access later" line. `LocalEventSource` protocol (m3-02 store fills
  it; the app stand-in returns no events). Source contains no networking API (test enforced).
- **Never watch** (`NeverWatch/`): `Exclusion` (`kind`: `bundle_id`, `host`, `title_contains`, as DATA_MODEL
  `exclusions`; `source`: `builtin`, `user`), `NeverWatch.parse`, the screen 9 chips (locked: 1Password, Banking
  sites, Private windows), `NeverWatchStore` (locked entries cannot be removed) and the protocol
  **`ExclusionSource`** (`func currentExclusions() -> [Exclusion]`, `Sendable`) that the m3-02 observer reloads every
  2 s. Entries apply locally before `ExclusionService` is called.
- **Design system** (`Design/`): `Tokens` (pricing v3 palette: paper `#f4f5f2`, paper 2 `#eceee9`, ink `#0b1220`,
  ink 2 `#3a4552`, muted `#5d6874`, rule `#dde2df`, chrome `#0c1422`, chrome 2 `#151f2f`, chrome ink `#eef2f6`,
  chrome mute `#93a0b0`, cyan `#67e8f9`, blue `#4c8dff`, amber `#f2b33d`, green `#3fcf8e`; spacing, radii, type
  scale), `MetaItems`, `OrphanGuard`, `BuddyMood`/`BuddyLine`, `TimeHeadline`, `MotionPolicy` and `TypedText`
  (Reduce Motion shows final states), SwiftUI helpers (paper canvas, dark floating cards).
- **Copy** (`Onboarding/OnboardingCopy.swift`): every onboarding and Today string in one place, from ONBOARDING
  section 13; `RetentionConfig` supplies the screen 5 numbers (`OFFLOAD_TEXT_TTL_DAYS` 7, `OFFLOAD_RAW_TTL_DAYS` 30,
  derived-model rule), never hard-coded in copy.
- **Accessibility identifiers**: `A11yID` (`onboarding.<n>.primary`, `.secondary`, `.skip`, `today.empty`, ...).

## Design note
- **Structure**: `OffloadMacApp` (executable, 1 file) → `OffloadMac` library: `Shell/` (launch, `AppModel`, root
  and menu bar views), `Onboarding/` (screens, flow, state, store, services, copy, views), `Permissions/`,
  `LocalNow/`, `NeverWatch/`, `Today/`, `Design/`. Pure value types carry the logic; `@MainActor` view models wrap
  them; views only draw. AppKit and TCC calls sit in `Live*` types the tests never construct.
- **State machine**: `OnboardingFlow.perform(_ action:)` is the only mutator; it returns `[OnboardingEffect]`
  (start capture, start uploader, record consent, patch profile, apply exclusions, set login item, relaunch) that the
  `@MainActor` `OnboardingModel` runs against the injected services. Effects are values, so tests assert "no upload
  effect before Start sending" without timers or I/O. State is saved after every action.
- **Faked**: sign-in, consent, profile, exclusions upload, connections, instant read, login item, permissions, local
  events. In the app the stand-ins are local only: sign-in says it is not ready in this build and offers Local mode;
  connecting says the same; profile answers and exclusions are kept on this Mac.
- **Deferred**: real sign-in and device enrollment (m1-04 / m3-02 enrollment client), consent POST and uploader
  (m3-02), observer reading `ExclusionSource` and filling `LocalEventSource` (m3-02), profile PATCH (M5), connections
  and instant read (M2/M5), ConnectionGroups (m5-05), recordings import (m3-05), Today content and weekly review
  (m5-05), snapshot tests per screen light and dark (needs the m3-03 bundle; logic is tested here), notifications
  for missing permissions (`ReaskPolicy` decides; delivery lands with the first weekly review), Pause in the menu bar
  item (needs the observer, m3-02), a dark palette (the window is pinned to light), Settings screens, Sample week data
  beyond a labelled synthetic headline, PERF test (manual, ROADMAP M3).
- **Review 1 additions**: "Move and reopen" is built after all (`Shell/AppMover.swift`, tested with fake file steps):
  an older `/Applications/Offload.app` goes to the Trash, the new copy is opened, a failure says to drag it in Finder.
  The menu bar item has "Don't watch <app in front>" and "Never watch an app or site…" (the same fields as screen 9),
  so Never watch works in Local mode, which is every person's mode until sign-in lands.

## Red tests (write these first, run them, see them fail)
Folder `apps/mac/Tests/OffloadMacTests/M304/`, Swift Testing, every test `@Test("TAG: ...")` inside
`@Suite struct M304` (tests in extensions of `M304` across files). Ported names keep the old name in the sentence.

| Tag | Tests (short) |
|---|---|
| SHELL | first run opens onboarding, finished opens Today; `--onboarding`/`--onboarding-screen`; translocated path asks to move; unreadable buffer offers Start fresh; Today empty state has no invented number |
| ONBOARDING | happy path 0 to 13; Not now → Local, skips 5 to 12; Keep it on this Mac → Local; every question screen has Skip and skipping writes no profile field; an answer writes only its field; goals ≤ 3 × 80 chars one line; rhythm defaults; state survives relaunch; Screen Recording relaunch resumes at 3 with "Screen reading is on."; nothing is uploaded before "Start sending"; screen 5 numbers from config; Input Monitoring never requested; capture starts after permissions with one on; sign-in waiting, 5 min timeout, offline; screen 13 copy; open at login; new notice version → screen 5; abandoned setup → resume + Finish setting up; Reduce Motion typed text; theFlowKeepsWhatWasTyped; one primary and unique identifiers; connect apps; recordings only after consent |
| MODE | product modes table rows; Local banner wording |
| REASK | one notification per missing permission; banner 30 days; Dormant two reminders and no modal after setup |
| PERMS | promptOnceThenSettings; aConfirmedGrantSurvivesAPreflightFalseNegative; settingsLinksArePrivacyPanes (14, 15, 26, fallback); 1.5 s ticks; Show in Finder rule; quit and reopen; control names by version |
| NOW | NOW-1 to NOW-5 (old s34 names); NOW-6 zero model calls and zero uploads; real span headline; pointer flies once; fixture day file |
| NEVERWATCH | appsAndSitesAreToldApart; locked entries; applied locally before the server call returns; observer source sees changes |
| COPY | no em dash, banned word or the no-dry-run terms; no internal terms, captions lowercase |
| TOKENS | pricing v3 palette; text 4.5:1 on paper and chrome; hero type |
| TIME | blocks, empty week headline only; maths as separate items, no percentages |
| META | middle-dot strings become separate items |
| TYPE | last two words stay together |
| BUDDY | lowercase short line; moods follow the observer and what is waiting |

## Out of scope
The observer, masker, store, uploader and enrollment client (m3-02); signing, bundle, Sparkle, self-check, NOTICE
(m3-03); recordings import (m3-05); any network call; any model call; editing `packages/contracts`.

## Verify
`bash slices/m3-04-mac-onboarding/verify.sh`. On Linux it prints `m3-04-mac-onboarding: SKIPPED (needs macOS)` and
exits 0; with `REQUIRE_MAC=1` (CI `mac` job) a skip fails. The CI `mac` job's plain `swift test` runs this suite.

## Scope changes
- `apps/mac/Package.swift`: additive executable product `Offload` and target `OffloadMacApp` (m3-03 rebases on it).
- `apps/mac/**` is listed in m3-02's `owns`; m3-02 has not started, so this slice writes only its own folders above
  and leaves `OffloadMac.swift` and `SmokeTests.swift` for m3-02 to delete.
- `depends_on: [m3-02-mac-capture-upload]` as the ROADMAP says, but built first against protocols (orchestrator
  order). The observer, store and uploader plug into `ExclusionSource`, `LocalEventSource`, `CaptureControl` and
  `Uploader`.
- NOTICE (m3-03's file): the clicky entry should change from "Planned" to ported for
  `apps/mac/Sources/OffloadMac/Permissions/ScreenPermissionGate.swift` (WindowPositionManager.swift gate and the
  confirmed-grant rule) and `PermissionTicker.swift` (CompanionManager.swift 1.5 s polling).
- Tags are letters only (verify.sh counts `Test "[A-Z]+: ..."`), so `NOW-1`..`NOW-6` live inside `NOW:` test names.
- The local now line follows ONBOARDING section 5 (`·` separators), not the old `Last 10 min: ..., ....` format.
  The remark is built from the numbers ("that's you, mostly in cursor."); ONBOARDING section 5's example is updated
  to match.
- TOKENS: the old s33 tests compared against the old web accent `#D8F55A`; v2 has no web tokens yet, so the tests
  pin the pricing v3 palette the owner approved, and the contrast test uses its paper and chrome. When
  `packages/contracts` gains tokens, both clients read them.
- TIME: `TimeHeadline` is a reduced port (no s23 `TimeScreen` sections, which are gone); same rules.
- ConnectionGroups is not ported here: it belongs with the Connections screen in m5-05.
- `docs/GLOSSARY.md` gains "Local now summary" and "Never watch" (used by ONBOARDING, missing from the glossary).
- Review 1 (logs/m3-04-mac-onboarding.review1.md) changes:
  - verify.sh: `BASE` is `7407300` (the branch was rebased onto the W1-A specs). The branch also stacks m3-09, so the
    scope check reads only commits whose subject starts with `m3-04-mac-onboarding: ` and runs on every platform. The
    pass count comes from Swift Testing's `Test run with N tests ... passed` summary, because the console printed a
    `passed` line for only 14 of 64 passing tests in CI run 43652387723. Still to do before `done`: one run on macOS
    with `REQUIRE_MAC=1` (ci.yml, m3-03's file, runs only m3-02's verify).
  - Light and dark (ONBOARDING section 1): the main window and its sheets are pinned to light
    (`.preferredColorScheme(.light)`) until a dark paper palette is designed; system controls would otherwise draw
    dark-mode text on the light canvas. Dark mode is deferred to the design-system follow-up.
  - The screen 13 menu bar pointer reads "Tell it not to watch an app, from here." until Pause exists (m3-02); the
    ONBOARDING text keeps the full line for the finished product. Screen 13 in Local mode says capture starts with a
    later update while `CaptureControl.isRunning` is false, and the menu bar says "not watching yet.".
  - A confirmed Screen Recording grant survives up to 2 false checks in a row, not forever: 3 false checks or a failed
    capture (`PermissionTicker.screenCaptureFailed`, for m3-02's frame-failure signal) drop it, and the loss allows one
    more notice (10.3).
  - `PATCH /v1/profile` is sent only while sending; answers given before consent stay in the local state.
  - Screen 5's "every batch sent from this Mac in the last 7 days" uses the 7-day local egress ledger (ADR 0035), not
    `OFFLOAD_TEXT_TTL_DAYS`. "Read the privacy details" links to the public repo's `docs/SECURITY_PRIVACY.md` until
    Offload's own policy exists (OQ-17).
  - "Personal Chrome profile" (Q5 optional chip) is not offered: DATA_MODEL `exclusions` kinds (`bundle_id`, `host`,
    `title_contains`) cannot scope an exclusion to one browser profile. It needs a profile-aware kind in
    `packages/contracts` and observer support (m3-02).
  - "Banking sites" (locked chip) carries no entries of its own: it relies on the built-in list
    `packages/masking/src/exclusions.builtin.json` that m3-02 ports. **m3-02 dependency**: until that list is loaded
    into `NeverWatchStore`'s built-ins, the screen 5 promise "banking apps … are skipped entirely" is not covered on
    the Mac.
  - NOTICE (m3-03's file) must move the clicky entry from "Planned" to ported before this slice can be `done`
    (AGENTS Definition of done item 5).
- Review 2 (logs/m3-04-mac-onboarding.review2.md) changes:
  - `owns` no longer lists `apps/mac/Sources/OffloadMacApp/**`: m3-09 edits that file too (its SPEC lists it in
    `paths_in_scope`, commit `0e078b4`), so it is shared, not owned. verify.sh now matches this slice's commits on the
    subject line only, and fails when a commit of another slice (`<slice-id>: ` subject) changes a path in `owns`.
  - Launch: the uploader starts when the person is sending and no new notice waits; both permissions are read at
    every launch (row 11.4) and every 5 s in normal running (row 11.3); a launch on screen 2 that finds Screen
    Recording on resumes at screen 3 (row 11.1, macOS's own "Quit & Reopen").
  - Start sending also sends what was kept on the Mac before consent: the person's Never watch entries
    (`POST /v1/exclusions`) and the answered profile fields (`PATCH /v1/profile`). Nothing is sent if the consent call
    fails.
  - Screen 11 Import stays on the screen and records no import until m3-05 builds it.
  - "Move and reopen" copies beside the destination, swaps it in (`replaceItemAt`), clears `com.apple.quarantine` and
    opens the copy. Clearing quarantine follows LetsMove: the person already opened this copy, which is when
    Gatekeeper checked it. Human-gated: the owner checks it on a real Mac with the m3-09 test build.
  - "Private windows" (locked chip) relies on window-title markers ("Private Browsing", "InPrivate", "Incognito").
    Safari private windows and Chrome Incognito on macOS may show none. **m3-02 dependency**: observer-side
    private-window detection plus the built-in list, so screen 1's and screen 5's promise is kept on the Mac.
  - The onboarding state (including the Never watch list) is a plain property list in `UserDefaults`;
    SECURITY_PRIVACY section 6 now says so, and it moves into the sealed store with m3-02.
  - Type uses fixed point sizes from the token scale, so it does not follow a system text size; macOS 14 SwiftUI has
    no Dynamic Type for these fonts. The custom button styles draw a focus ring from `isFocused`. Both are checked by
    the owner on a real Mac.
  - MIGRATION 5.5 `ahaAsksOnlyOnceScreenRecordingIsOnAndStopsWhenItHasSomething` is carried as
    `NOW: the pointer flies once, on the first line with a full minute, and refreshes every 5 s`. Two rules change by
    ONBOARDING section 5: the summary refreshes every 5 s (not 15 s), and it is not gated on Screen Recording, because
    it reads the local buffer, which Accessibility capture fills too.
  - Still deferred (ONBOARDING section 11): row 11.2's banner and the one notification when macOS pauses screen reading
    (needs the observer's frame-failure signal, m3-02, which calls `PermissionsModel.screenCaptureFailed`); the
    notifications of 10.2 (first weekly review); rows 11.5, 11.7, 11.9, 11.10 and 11.12 (their backends).
- m3-05 (recordings import) hooks screen 11 into this slice's files, so `owns` lists files instead of the `Shell/**`
  and `Onboarding/**` folders: `Shell/AppModel.swift`, `Onboarding/Services.swift`, `Onboarding/OnboardingModel.swift`
  and `Onboarding/OnboardingView.swift` are shared with m3-05 (its SPEC, Scope changes). Every new file in those
  folders must be added to `owns` here or to the slice that writes it.
- **Rebase onto main (2026-11-22, m3-03 merged)**: m3-03 made `OffloadMac` the executable target (product
  `Offload`, Sparkle linked, `@main` in `OffloadMac.swift` with `--self-check`). Main's `Package.swift` is kept as
  is, so the target `OffloadMacApp` and the `OffloadMac` library product are gone. The SwiftUI `App` moved from
  `Sources/OffloadMacApp/OffloadApp.swift` to `Sources/OffloadMac/App/OffloadApp.swift` (no `@main`); m3-03's entry
  answers `--self-check`, then `--version` (m3-09), then starts it. m3-03's placeholder AppKit menu became
  `App/AppUpdates.swift` (`UpdateMenu`: a line per permission lost in an update, then "Check for Updates…" or the
  status line, shown before Quit by `MenuBarContent`; tests `M304` `ShellUpdatesTests.swift`). `paths_in_scope` names
  `apps/mac/Sources/OffloadMac/App/**` instead of `apps/mac/Sources/OffloadMacApp/**`.
  The Package.swift row of the Contract (additive `OffloadMacApp` target) no longer applies.
