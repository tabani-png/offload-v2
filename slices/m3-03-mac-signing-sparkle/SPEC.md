---
id: m3-03-mac-signing-sparkle
title: App bundle, Developer ID signing, notarization and Sparkle updates in the CI mac job and the release workflows, with placeholder secret names and a clean skip when secrets are absent
milestone: M3
status: done
depends_on: [m3-02-mac-capture-upload]
parallel_safe: true
human_gated: true
model_tier: sonnet
size: M
parallel_group: M3-C
owns: [.github/workflows/**, apps/mac/Package.swift, apps/mac/Package.resolved, apps/mac/Packaging/**, apps/mac/Sources/OffloadMac/Updates/**, apps/mac/Sources/OffloadMac/SelfCheck/**, apps/mac/Sources/OffloadMac/OffloadMac.swift, apps/mac/Tests/OffloadMacTests/M303/**, NOTICE]
verify: bash slices/m3-03-mac-signing-sparkle/verify.sh
min_tests: 19
paths_in_scope: [.github/workflows/**, apps/mac/Package.swift, apps/mac/Package.resolved, apps/mac/Packaging/**, apps/mac/Sources/OffloadMac/Updates/**, apps/mac/Sources/OffloadMac/SelfCheck/**, apps/mac/Sources/OffloadMac/OffloadMac.swift, apps/mac/Tests/OffloadMacTests/M303/**, scripts/tests/m3-03-mac-signing-sparkle/**, slices/m3-03-mac-signing-sparkle/**, NOTICE]
paths_out_of_scope: [ee/**, services/**, packages/**, apps/web/**, apps/mac/Sources/OffloadObserver/**, apps/mac/Sources/OffloadMasker/**, apps/mac/Sources/OffloadStore/**, apps/mac/Sources/OffloadUploader/**, apps/mac/Sources/OffloadImport/**, apps/mac/Sources/OffloadActuator/**, apps/mac/Sources/OffloadContracts/**, docs/**, .env.example]
red_tests: [SIGN, RELEASE, BUNDLE, SPARKLE]
---

# m3-03-mac-signing-sparkle

## Summary
Turns the `swift build` output into the signed, notarized, self-updating `Offload.app` that the
[M3 exit](../../docs/ROADMAP.md#m3-capture-to-cloud) needs ("a Sparkle update installs without losing permissions").
Implements [ADR 0024](../../docs/adr/0024-client-stacks.md) (signing and identity, Sparkle at M3; this ADR is the
"new dependency needs an ADR" record for Sparkle that [DEPLOYMENT section 4](../../docs/DEPLOYMENT.md#4-updates-sparkle-2-from-m3)
asks for), [DEPLOYMENT section 3](../../docs/DEPLOYMENT.md#3-signing-notarization-and-the-disk-image) (bundle layout,
Info.plist, entitlements, signing order, notarize and staple), section 4 (Sparkle 2), section
[6](../../docs/DEPLOYMENT.md#6-ci) (mac job shape, `release-mac.yml`, `promote-mac.yml`) and
[section 13](../../docs/DEPLOYMENT.md#13-secrets-handling) (release secrets). Folds in the old plan's W1-B tasks
T-B3, T-B4 and T-B8 ([WAVE1.md](../../docs/WAVE1.md)).

**Credentials are placeholders.** Every credential is a secret *name* in the protected `release` environment:
`DEVELOPER_ID_P12_BASE64`, `DEVELOPER_ID_P12_PASSWORD`, `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_P8`,
`SPARKLE_ED_PRIVATE_KEY`. Public values are repository variables: `APPLE_TEAM_ID`, `SPARKLE_ED_PUBLIC_KEY`,
`OFFLOAD_DOWNLOADS_HOST`. None exists yet (operator items O1, O2, O3, O11, O13). Every step that needs one checks
presence as a boolean and, when absent, prints one line naming what is missing and succeeds. No step prints a value.

`human_gated: true`: the owner supplies O1 to O3 and O11 for the first real signed release, and the manual ROADMAP
test `SPARKLE: an update signed with the EdDSA key installs and keeps Accessibility and Screen Recording grants` runs
on his Mac (spike S1 territory) and is recorded in the PR. The slice reaches `done` without those: its red tests run
with the secrets absent, and the Swift part runs in the CI `mac` job. CI on GitHub also needs operator items O4
(`workflow` scope) and O12 (macOS runner capacity); until then the Swift part is run on the owner's Mac and recorded.

**Old repo.** Job shape from [MIGRATION section 5.2](../../docs/MIGRATION.md#52-cimac-release-workflow)
(`ci/mac-release-workflow`) and the checksum-verified pinned-tool download from
[section 5.1](../../docs/MIGRATION.md#51-pr-41-releasemac-testable-m0-installable-build) (PR #41), both already
summarised in DEPLOYMENT section 6.2. They are written fresh from that description, not copied. Nothing is ported from
PRs #43 to #45 (their CI files are dropped in MIGRATION 5.6). **This slice never edits the old repo or its
`release/mac-testable` branch**; it works only in this repository.

## Contract
- **Dependency**: Sparkle 2 through SwiftPM, `.package(url: "https://github.com/sparkle-project/Sparkle", exact:
  "2.10.1")` (the newest 2.x on 2026-11-14; check its security notes when starting and record a newer 2.x under "Scope
  changes"), linked only into `OffloadMac`. `Package.resolved` committed. Sparkle (MIT) added to `NOTICE` in the same
  commit, with its license text.
- **Shared files in M3-C**: this slice owns `apps/mac/Package.swift`, `.github/workflows/**`, `NOTICE` and the app
  entry file `apps/mac/Sources/OffloadMac/OffloadMac.swift` (one line wiring the updater and "Check for Updates…"
  into the menu; if m3-02 named the entry file differently, use it and record it under "Scope changes"). m3-04 to m3-06
  stay out of these while it runs. It does not edit `docs/**`: DEPLOYMENT already describes the target; if the build
  must differ, stop and write a "Scope changes" note.
- **Packaging scripts** (`apps/mac/Packaging/`, Bash 3.2, `set -euo pipefail`, never `set -x`):
  - `bundle.sh <flavour>` (`release` or `dev`): assembles `Offload.app/Contents/{Info.plist, MacOS/Offload,
    Frameworks/Sparkle.framework, Resources/THIRD_PARTY_NOTICES.txt}` from the `swift build -c release` product.
    `Info.plist` comes from `Info.plist.template`: `CFBundleIdentifier` `ai.offload.mac` (dev `ai.offload.mac.dev`;
    the default of [OQ-16](../../docs/OPEN_QUESTIONS.md#oq-16-mac-distribution-and-signing) until O2 locks it),
    `CFBundleShortVersionString` from the tag, `CFBundleVersion` from the CI run number (only increases),
    `LSMinimumSystemVersion` `14.0`, `LSUIElement` `true`, `LSApplicationCategoryType`, `NSScreenCaptureUsageDescription`
    as DEPLOYMENT 3.2, and `SUFeedURL` (`https://$OFFLOAD_DOWNLOADS_HOST/appcast.xml`), `SUPublicEDKey`,
    `SURequireSignedFeed` `true`, `SUVerifyUpdateBeforeExtraction` `true`. Without `OFFLOAD_DOWNLOADS_HOST` or
    `SPARKLE_ED_PUBLIC_KEY` the feed keys are left out and the app's updater reports "updates off in this build".
  - `check-bundle.sh <app>`: fails on a Mach-O under `Resources/` (magic bytes, no `file` dependency), an executable
    that `${CODESIGN:-codesign} --verify --strict` rejects, a missing `THIRD_PARTY_NOTICES.txt`, or a size above
    `BUNDLE_MAX_MB` (default 50, the DEPLOYMENT 3.1 planning figure).
  - `sign.sh <app> <mode>` with mode `adhoc` or `developer-id`. `developer-id` needs `DEVELOPER_ID_P12_BASE64` and
    `DEVELOPER_ID_P12_PASSWORD`; when either is absent it prints `signing: skipped (absent: <names>)` and exits 0. When
    present it creates a temporary keychain, imports the certificate, signs inside-out (Sparkle's nested helpers one by
    one, then `Sparkle.framework`, then `Offload.app`; Sparkle's XPC services removed first; never `--deep`; every call
    `--options runtime --timestamp`), and on non-macOS exits 1 with `signing: needs macOS` before reading any value.
    `Offload.entitlements`: hardened runtime, no capture entitlement (DEPLOYMENT 3.3).
  - `notarize.sh <app> <version>`: needs `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_P8`, else skips the same way. Zips with
    `ditto -c -k --sequesterRsrc --keepParent`, `xcrun notarytool submit --wait`, staples and validates the app, builds
    and signs the DMG, notarizes and staples it, and uploads `notarytool log` on failure. The key file is written to a
    temp path with mode 0600 and removed in a trap.
  - `appcast.sh <zip> <version> <channel>`: needs `SPARKLE_ED_PRIVATE_KEY`, else skips. Signs the archive with
    Sparkle's `sign_update` and writes the appcast item with `generate_appcast` (deltas, `sparkle:channel` `beta` for
    tester items). Sparkle's tools come from the pinned release archive, verified against its published checksum
    before use (the PR #41 pattern).
  - Secrets reach scripts only as environment variables set by the workflow step that needs them; scripts never echo
    them, never pass them as command arguments where avoidable (`--password` from a file or stdin), and the test suite
    greps their output for canary values.
- **App code** (`apps/mac/Sources/OffloadMac/Updates/`): `UpdaterController` wrapping `SPUStandardUpdaterController`
  (daily check, "Check for Updates…"); a `CaptureLifecycle` protocol with `prepareForUpdate()` (flush the upload queue,
  stop capture cleanly) called from Sparkle's will-install delegate; `allowedChannels` returns `["beta"]` only when the
  "Get early builds" setting is on; after relaunch the app re-checks both permissions through the permission source
  m3-02 provides. `SelfCheck/`: `Offload --self-check` starts capture against a fake permission source, writes nothing
  outside a temp `HOME`, and exits 0, for the installed-copy smoke test (if m3-02 already added it, reuse it).
- **Workflows**:
  - `ci.yml` `mac` job (shape of DEPLOYMENT 6.2): `swift build -c release`, `bundle.sh release`, `sign.sh adhoc`,
    `check-bundle.sh`, zip with `ditto`, **upload the artifact before any test step**, installed-copy smoke test from a
    `ditto` copy in a temp folder with `env -i HOME=<temp> PATH=/usr/bin:/bin:/usr/sbin:/sbin`, then `swift test`, the
    m3-02 slice step and an m3-03 slice step (each its own step, timeout, `continue-on-error: true`), then the result
    step that fails if any failed. A path filter limits the job to `apps/mac/**`, `packages/contracts/**` and
    `.github/workflows/**`. No secret is referenced anywhere in `ci.yml`; the job prints
    `developer id signing: runs in release-mac.yml`.
  - `release-mac.yml`: `on: push: tags: ["v*"]` and `workflow_dispatch`; `environment: release`; `runs-on: macos-26`
    (hosted only, [OQ-25](../../docs/OPEN_QUESTIONS.md#oq-25-ci-capacity-for-macos)); `permissions: contents: write`
    only on the publish step's job. A first step `secrets` exports `has_signing`, `has_notary`, `has_sparkle` as
    `${{ secrets.X != '' }}` booleans; each later step has `if:` on the matching output and a sibling step that prints
    the skip line when false. Steps: bundle, `sign.sh developer-id`, `check-bundle.sh`, `notarize.sh`, `appcast.sh
    beta`, checksums, upload. Temporary keychain deleted in an `if: always()` step.
  - `promote-mac.yml`: `workflow_dispatch` only, `environment: release`, inputs `action` (`promote`, `halt`,
    `rerelease`) and `version`; promote sets `sparkle:phasedRolloutInterval`, halt removes the item, re-release
    publishes older code under a higher version.
  - Action references stay pinned by tag as today (SHA pinning is the M8 test `CI: every action reference is pinned
    by a 40-char SHA`).
- Bun tests live in `scripts/tests/m3-03-mac-signing-sparkle/` and run on Linux: they execute the packaging scripts
  against fixture bundles (built in a temp dir by the test) with a fake `codesign` on `PATH`, and parse the workflow
  YAML with `Bun.YAML.parse`. Swift tests live in `@Suite struct M303` under
  `apps/mac/Tests/OffloadMacTests/M303/`.

## Red tests (write these first, run them, see them fail)
Bun folder `scripts/tests/m3-03-mac-signing-sparkle/` (tags SIGN, RELEASE, BUNDLE; `min_tests` counts these). Swift
folder `apps/mac/Tests/OffloadMacTests/M303/` (tag SPARKLE; runs only on macOS, at least 4 tests).

| Tag | Test name | Asserts |
|---|---|---|
| SIGN | SIGN: developer-id signing without its secrets prints the names it lacks and exits 0 | empty env (`env -i`) |
| SIGN | SIGN: no packaging script prints a secret value | canary values in env; stdout and stderr searched; on Linux `sign.sh` stops at `needs macOS` |
| SIGN | SIGN: notarize skips cleanly without the App Store Connect secrets | |
| SIGN | SIGN: appcast skips cleanly without the Sparkle private key | |
| SIGN | SIGN: signing is inside-out and never uses --deep | static check of `sign.sh` |
| SIGN | SIGN: every codesign call uses --options runtime --timestamp | static check |
| RELEASE | RELEASE: every secret a workflow references is one of the six placeholder names | |
| RELEASE | RELEASE: no job that runs on pull_request references a secret | |
| RELEASE | RELEASE: release-mac runs only in the release environment, on a tag or manual dispatch, on macos-26 | |
| RELEASE | RELEASE: the temporary keychain is deleted in a step that always runs | |
| RELEASE | RELEASE: the secrets check exposes only true or false | no `secrets.` reference inside any `run:` text |
| RELEASE | RELEASE: the mac job uploads the bundle before any test step | |
| RELEASE | RELEASE: promote-mac is manual only and offers promote, halt and rerelease | |
| BUNDLE | BUNDLE: a Mach-O under Resources fails the bundle check | fixture |
| BUNDLE | BUNDLE: an unsigned executable fails the bundle check | fake `codesign` |
| BUNDLE | BUNDLE: a missing third-party notices file fails the bundle check | |
| BUNDLE | BUNDLE: a bundle over the size budget fails the bundle check | |
| BUNDLE | BUNDLE: Info.plist has the bundle id, macOS 14.0 minimum, menu bar flag and the four Sparkle keys | `plutil`-free XML parse |
| BUNDLE | BUNDLE: a dev build gets the .dev bundle id and a missing downloads host leaves the feed keys out | |
| SPARKLE | SPARKLE: the updater flushes the upload queue and stops capture before it installs | fake `CaptureLifecycle` (Swift) |
| SPARKLE | SPARKLE: beta items are offered only when Get early builds is on | (Swift) |
| SPARKLE | SPARKLE: an Info.plist without a signed https feed turns updates off | (Swift) |
| SPARKLE | SPARKLE: after an update relaunch both permissions are checked again | fake permission source (Swift) |

Manual, recorded in the PR (ROADMAP M3): `SPARKLE: an update signed with the EdDSA key installs and keeps
Accessibility and Screen Recording grants`, plus a tampered archive and a tampered feed both refused. Needs O1 to O3
and O11.

## Out of scope
Anything in the old repo, including `release/mac-testable` and its `mac-release.yml`; the Mac capture code
(m3-02), onboarding screens (m3-04), recordings import (m3-05), key wraps (m3-06); the Apple enrolment, certificates,
EdDSA key generation and the appcast host (operator items); the `.internal` staging bundle id (OQ-16 (c), M8);
pinning actions by SHA (M8); `deploy-cloud.yml` and `nightly.yml`; spike S1 and S2 write-ups (into ADR 0006 by the
owner's Mac run).

## Verify
`bash slices/m3-03-mac-signing-sparkle/verify.sh`. On Linux it runs the bun suite (SIGN, RELEASE, BUNDLE) and prints
`swift part: SKIPPED (needs macOS)` for SPARKLE; with `REQUIRE_MAC=1` (CI `mac` job) a skipped Swift part fails.

## Scope changes
Recorded by the implementer (2026-11-14). No path outside `paths_in_scope` changed; `docs/**` is untouched.
- **Sparkle version**: 2.10.1 confirmed as the newest 2.x (released 2026-10-25, after 2.9.6's installer security
  fixes). Tag commit `ab7d71291238df6e0492143b120c9b696a35f603` pinned in `Package.resolved` (format 2); the tools
  archive is pinned to GitHub's published digest `sha256:1a856d2a…cf27`.
- **Executable target**: `apps/mac` had no executable, and the only in-scope source folder is `Sources/OffloadMac`,
  so `OffloadMac` became an `.executableTarget` and the library product became `.executable(name: "Offload")`
  (`@main` in `OffloadMac.swift`, which keeps `OffloadMacTodo` for `SmokeTests.swift`). An rpath
  `@executable_path/../Frameworks` is added as a linker flag so the bundled app loads Sparkle.
- **Interfaces m3-02 did not provide yet**: `PermissionSource` (and `Permission`) and `CaptureLifecycle` are defined
  in `Updates/`; `CaptureLifecycle` also has `start()` for the self-check. `CaptureNotStarted` and
  `SystemPermissionSource` stand in until m3-02 conforms its real types.
- **Extra packaging files**: `lib.sh` (shared presence checks), `fetch-sparkle-tools.sh` (the checksum-verified
  download, testable on its own), `promote.sh` and `appcast-edit.ts` (for `promote-mac.yml`), `README.md`.
- **appcast.sh** also needs the public `OFFLOAD_DOWNLOADS_HOST` for the download URL prefix; it checks the private
  key first, so the empty-environment skip line names only `SPARKLE_ED_PRIVATE_KEY`.
- **Ad hoc mode** passes `--timestamp=none`: an ad hoc signature cannot be timestamped. Developer ID always gets a
  real `--timestamp`.
- **Publishing**: `release-mac.yml` publishes a GitHub prerelease (the only `contents: write` job) and uploads the
  files as an artifact; `promote-mac.yml` uploads the edited, re-signed appcast as an artifact. Copying to the
  `downloads.` host needs cloud credentials (O7, O13) and is not automated.
- **Path filter**: a `changes` job (plain `git diff`, no extra action) gates the `mac` job.
- **Extra tests** beyond the table: an ad hoc signing order check through a fake `codesign`, the Sparkle tools
  checksum refusal, an unknown signing mode, a good bundle passing, malformed `bundle.sh` inputs, the entitlements
  file, the mac job path filter, appcast promote and halt, and a fifth Swift test for the self-check.
- **Test fixes after red** (test bugs, not behaviour): the secret-reference regex now ignores `steps.secrets.outputs`
  (the SPEC names that step `secrets`), and the mac-job suite match ignores the result step's echo lines.
