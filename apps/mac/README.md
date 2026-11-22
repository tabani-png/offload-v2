# apps/mac

Swift 6 / SwiftUI thin client for macOS 14+. SwiftPM package (see Package.swift): the `Offload` executable (target
`OffloadMac`: the app, its menu bar item and main window, updates and `Offload --self-check`), the library targets and
one test target. Sparkle 2 is the one dependency (m3-03).

It captures, masks on device, uploads masked observation batches, and shows the UI. It holds no brain.

Targets (m3-02 capture and upload, m3-05 import, m3-14 one app):

| Target | What it holds |
|---|---|
| `OffloadContracts` | Types generated from `packages/contracts/schemas` (`bun packages/contracts/scripts/gen-swift.ts`, committed in `Generated/`), JCS (RFC 8785), time and ULID helpers |
| `OffloadStore` | AES-256-GCM day files and egress ledger with Keychain-wrapped day keys, 7-day purge, reveal map, upload queue state |
| `OffloadMasker` | Structured-secret detectors, stable keyed pseudonyms, the device leak scan, scrypt key wrap |
| `OffloadObserver` | Focus, bounded Accessibility walk, OCR fallback, exclusions, pause, permissions. No networking (test enforced). `Live/` has the macOS glue |
| `OffloadUploader` | The egress guard: one host, closed types, detectors again, signed batches, local egress ledger, device key, enrollment client |
| `OffloadImport` | Recordings import: folder rules, frame reading, ingest through the masker and the user's exclusions (m3-05) |
| `OffloadMac` | The app: one `@main` entry (`OffloadMac.swift`), one composition root (`Composition/`, m3-14) that decides at launch what starts (updater, capture, uploader) from the consent state, `CaptureRuntime` (m3-02), onboarding and shell (m3-04), recordings (m3-05) |
| `OffloadActuator` | Marker until its slice |

Tests live in `Tests/OffloadMacTests/<slice>` (one `@Suite` per slice, for example `M302`, `M314`). The freshness test runs `bun`, so install Bun first.
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
`ImportSink` protocol. The real masker (`ImportMaskerAdapter`, m3-02's masker with the capture's key) and the
uploader-backed sink (`UploaderImportSink`) are wired by m3-14's composition root (`Sources/OffloadMac/Composition/`);
on-device OCR and the local store come with m3-10, so until then the app shows the folder summary and the menu says the
import is coming. `Sources/OffloadMac/Recordings/` holds screen 11's
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

Build progress (slice m3-13): `Sources/OffloadMac/BuildProgress/` is the Builds screen. `BuildDetail.swift` decides what
one build shows in pure code (`StepMapping` from the build loop's stages onto five rows, `HeadlineMap`, `AttemptRow`,
`HeldOutResult`, `BudgetMeter` and `Money` with half-up cents, `SavingLine`); `SampleBuild.swift` is the labelled
sample (`SampleTimeline.state(at:)`, the mockup's 92 ticks); `BuildRecordStore.swift` keeps the builds started on this
Mac (the API has no list route); `BuildProgressModel.swift` reads the builds API through m3-10's `BuildsClient` in
`.cloud` (poll every 2 s while live, backoff to 60 s, the OK, build plan step with the opportunity polled every 5 s for
at most 10 minutes, the two exact-hash approvals posted only from their buttons, the outcome after install) and plays
the sample in `.local`; `BuildCopy.swift` holds every string. The hand-off from Today and Weekly review
(`navigation.pendingBuild`) is read once when Builds appears. Tests: `Tests/OffloadMacTests/M313/`.
