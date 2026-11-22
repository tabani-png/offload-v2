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

Weekly review (slice m3-12): `Sources/OffloadMac/WeeklyReview/` holds the screen and its Settings section. In `.local`
it is counted from local insights (`ReviewContent.local`: tiles against your usual week, one sentence from a closed set
checked against its figures, goals with the hours of the repeats linked to them, up to 4 questions); answers are kept
on this Mac through `LocalAnswerStore`, so local ranking reads them at once. In `.cloud` it reads
`GET /v1/review/week?w=` and posts `POST /v1/review/answers`. `ISOWeek`, `ReviewSlot` and `ReviewSchedule` decide which
week is shown; `ReviewScheduler` keeps one repeating notification (`ai.offload.weekly-review`) at the review slot while
"Tell me when my review is ready" is on (off by default); `AppModel.live()` starts it through `WeeklyReviewHub`.
Settings keys: `ai.offload.review.day`, `ai.offload.review.time`, `ai.offload.review.notify`,
`ai.offload.review.offered`. The screen offers the notification once; clicking it opens the main window on this week's review
(`WeeklyReviewWindowOpener` on the menu bar label). Tests:
`Tests/OffloadMacTests/M312/`.

Build progress (slice m3-13): `Sources/OffloadMac/BuildProgress/` is the Builds screen. `BuildDetail.swift` decides what
one build shows in pure code (`StepMapping` from the build loop's stages onto five rows, `HeadlineMap`, `AttemptRow`,
`HeldOutResult`, `BudgetMeter` and `Money` with half-up cents, `SavingLine`); `SampleBuild.swift` is the labelled
sample (`SampleTimeline.state(at:)`, the mockup's 92 ticks); `BuildRecordStore.swift` keeps the builds started on this
Mac (the API has no list route); `BuildProgressModel.swift` reads the builds API through m3-10's `BuildsClient` in
`.cloud` (poll every 2 s while live, backoff to 60 s, the OK, build plan step with the opportunity polled every 5 s for
at most 10 minutes, the two exact-hash approvals posted only from their buttons, the outcome after install) and plays
the sample in `.local`; `BuildCopy.swift` holds every string. The hand-off from Today and Weekly review
(`navigation.pendingBuild`) is read once when Builds appears. Tests: `Tests/OffloadMacTests/M313/`.
