# apps/mac

Swift 6 / SwiftUI thin client for macOS 14+. SwiftPM package (see Package.swift): the `Offload` executable (target
`OffloadMac`: the app, its menu bar item and main window, updates and `Offload --self-check`), the library targets and
one test target. Sparkle 2 is the one dependency (m3-03).

It captures, masks on device, uploads masked observation batches, and shows the UI. It holds no brain.
See [ARCHITECTURE section 1](../../docs/ARCHITECTURE.md#1-mac-client) and [ADR 0007](../../docs/adr/0007-cloud-brain-thin-mac-client.md).

Build and test (macOS only): `swift build && swift test`. CI runs this in the `mac` job. It cannot build on Linux.

Run the app from a checkout: `swift run Offload`. Launch flags: `--onboarding` (show setup again) and
`--onboarding-screen <n>` (open setup at screen n, 0 to 13; [ONBOARDING.md](../../docs/ONBOARDING.md)). A `swift run`
binary is not a signed bundle, so macOS permission grants do not stick to it; daily use needs the bundled app (m3-03).

Test build (slice m3-09): `TestBuild/build-app.sh all <out-dir>` builds an ad hoc signed `Offload.app` (bundle id
`ai.offload.mac.dev`) and its zip; CI's `mac-artifact` workflow uploads it. `Offload --version` prints the version,
build, commit and bundle id. Install steps: [TestBuild/INSTALL_AND_TEST.md](TestBuild/INSTALL_AND_TEST.md).

Layout of `Sources/OffloadMac` (slice m3-04): `OffloadMac.swift` the process entry (`--self-check`, `--version`,
then the app); `App/` the SwiftUI `App` and the updater's menu lines; `Updates/` and `SelfCheck/` are m3-03's; `Shell/` launch route, app model, root and menu bar views; `Onboarding/`
the screen-by-screen flow (pure state machine, copy, injected services, views); `Permissions/` the Accessibility and
Screen Recording checks; `LocalNow/` the local now summary; `NeverWatch/` the exclusions the observer reads; `Today/`;
`Design/` tokens and shared rules. Tests: `Tests/OffloadMacTests/M304/`.

Recordings import (slice m3-05): `Sources/OffloadImport` reads a folder of screen recordings, screenshots or a
screenwatch archive on the Mac (stable file gate, recording names, fingerprint ledger, frames at most every 5 s and
1280 px, OCR, masker, exclusions, keyframe throttle) into masked observations for an import space, through the
`ImportSink` protocol. OCR, the masker and the uploader-backed sink come with m3-02 and the server half; until then the
app shows the folder summary and Import says it cannot read yet. `Sources/OffloadMac/Recordings/` holds screen 11's
body, Settings, Recordings ("Recordings…" in the menu bar item) and the floating progress panel. Tests:
`Tests/OffloadMacTests/M305/`.

Recordings analysed on this Mac (slice m3-10): `Sources/OffloadMac/OnDevice/` makes the import real in the test build
(Vision OCR, the interim masker with a local pseudonym key, `LocalImportSink` under
`Application Support/Offload/OnDevice/`, the default recordings folders, `OnDeviceRecordings.make`);
`Sources/OffloadMac/Analysis/` counts local insights in code (days, sessions, focus blocks, the things you repeat,
local ranking, the weekly review answers kept on this Mac, `InsightsStore`, `InsightsModel`); `Sources/OffloadMac/Backend/`
holds backend mode and the brain and builds clients (`.local` by default: no client exists); `Sources/OffloadMac/Navigation/`
holds the sidebar shell (Today, Weekly review, Builds, Recordings, Settings), the Sample data label and the launch
wiring. `TodayLive/`, `WeeklyReview/` and `BuildProgress/` start as placeholders owned by m3-11, m3-12 and m3-13.
Tests: `Tests/OffloadMacTests/M310/`.

Today on the Mac (slice m3-11): `Sources/OffloadMac/TodayLive/` replaces m3-10's placeholder with the mockup's Daily
screen wired to real data. In `.local` it reads m3-10's local insights (the header, the day grid of the top apps, What
you did, "Keeps coming back this week" with each count opening to how it was counted, one suggested fix whose Not now
and Leave it alone are kept on this Mac through `LocalAnswerStore`); in `.cloud` it reads the brain's day record for
the header and the planned `GET /v1/today` for the grid of kinds of work, What you did, the repeats and the suggested fix,
whose answers go to `POST /v1/opportunities/{id}/answer` (the next open opportunity then takes the card). One flag,
`TodayAPI.available` in `TodayLive/TodayAPI.swift`, is off until the server's Today API lands: off, `.cloud` shows a
sample under the amber label "Sample data: Today API not live yet", sends no request, has inert buttons and no menu
line; turn it on when m5-05's route is deployed. **OK, build** hands the fix to Build progress (`NavigationModel.startBuild`). The
menu bar item shows today's line above m3-04's menu. `TodayContent` builds every number from a Figure; `TodayLiveModel`
holds the day, the states (empty, importing, ready, not recorded, failed), the answers and the keys.
Tests: `Tests/OffloadMacTests/M311/`.
