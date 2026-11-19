# apps/mac

Swift 6 / SwiftUI thin client for macOS 14+. SwiftPM package (see Package.swift) with the `OffloadMac` library, the
`Offload` executable (target `OffloadMacApp`: the menu bar item and main window) and one test target.

It captures, masks on device, uploads masked observation batches, and shows the UI. It holds no brain.
See [ARCHITECTURE section 1](../../docs/ARCHITECTURE.md#1-mac-client) and [ADR 0007](../../docs/adr/0007-cloud-brain-thin-mac-client.md).

Build and test (macOS only): `swift build && swift test`. CI runs this in the `mac` job. It cannot build on Linux.

Run the app from a checkout: `swift run Offload`. Launch flags: `--onboarding` (show setup again) and
`--onboarding-screen <n>` (open setup at screen n, 0 to 13; [ONBOARDING.md](../../docs/ONBOARDING.md)). A `swift run`
binary is not a signed bundle, so macOS permission grants do not stick to it; daily use needs the bundled app (m3-03).

Test build (slice m3-09): `TestBuild/build-app.sh all <out-dir>` builds an ad hoc signed `Offload.app` (bundle id
`ai.offload.mac.dev`) and its zip; CI's `mac-artifact` workflow uploads it. `Offload --version` prints the version,
build, commit and bundle id. Install steps: [TestBuild/INSTALL_AND_TEST.md](TestBuild/INSTALL_AND_TEST.md).

Layout of `Sources/OffloadMac` (slice m3-04): `Shell/` launch route, app model, root and menu bar views; `Onboarding/`
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
