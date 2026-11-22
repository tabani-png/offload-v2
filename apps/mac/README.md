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
`ImportSink` protocol. OCR, the masker and the uploader-backed sink come with m3-02 and the server half; until then the
app shows the folder summary and Import says it cannot read yet. `Sources/OffloadMac/Recordings/` holds screen 11's
body, Settings, Recordings ("Recordings…" in the menu bar item) and the floating progress panel. Tests:
`Tests/OffloadMacTests/M305/`.
