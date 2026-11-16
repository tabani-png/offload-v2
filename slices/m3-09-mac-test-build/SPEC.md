---
id: m3-09-mac-test-build
title: Downloadable ad hoc signed Offload.app test build from CI, with an installed-copy smoke check and the install and test guide
milestone: M3
status: in_progress
depends_on: [m3-04-mac-onboarding]
parallel_safe: true
human_gated: true
model_tier: opus
size: S
parallel_group: M3-C
owns: [.github/workflows/mac-artifact.yml, apps/mac/TestBuild/**, apps/mac/Sources/OffloadMac/Version/**, apps/mac/Tests/OffloadMacTests/M309/**, scripts/tests/m3-09-mac-test-build/**]
verify: bash slices/m3-09-mac-test-build/verify.sh
min_tests: 24
paths_in_scope: [.github/workflows/mac-artifact.yml, apps/mac/TestBuild/**, apps/mac/Sources/OffloadMacApp/**, apps/mac/Sources/OffloadMac/Version/**, apps/mac/Tests/OffloadMacTests/M309/**, apps/mac/README.md, docs/DEPLOYMENT.md, scripts/tests/m3-09-mac-test-build/**, slices/m3-09-mac-test-build/**]
paths_out_of_scope: [ee/**, services/**, packages/**, apps/web/**, docs/adr/**, NOTICE, .github/workflows/ci.yml, apps/mac/Package.swift, apps/mac/Packaging/**, apps/mac/Sources/OffloadMac/OffloadMac.swift, apps/mac/Sources/OffloadMac/Shell/**, apps/mac/Sources/OffloadMac/Onboarding/**, apps/mac/Sources/OffloadMac/Permissions/**, apps/mac/Sources/OffloadMac/LocalNow/**, apps/mac/Sources/OffloadMac/NeverWatch/**, apps/mac/Sources/OffloadMac/Today/**, apps/mac/Sources/OffloadMac/Design/**, apps/mac/Sources/OffloadMac/Updates/**, apps/mac/Sources/OffloadMac/SelfCheck/**, apps/mac/Tests/OffloadMacTests/M303/**, apps/mac/Tests/OffloadMacTests/M304/**, apps/mac/Tests/OffloadMacTests/SmokeTests.swift]
red_tests: [PLIST, STAMP, ASSEMBLE, ADHOC, SMOKE, PINNED, ARTIFACT, GUIDE, VERSION]
---

# m3-09-mac-test-build

## Summary
Every push to the W1-H branch, every pull request and every manual run builds a release `Offload.app` from
`apps/mac`, signs it ad hoc, smoke-tests an installed copy and uploads `Offload-mac-<shortsha>.zip` with the install
guide as a GitHub Actions artifact, so the owner can install the onboarding work on a real Mac before m3-03's Developer
ID build exists ([M3](../../docs/ROADMAP.md#m3-capture-to-cloud); `human_gated` because the install, the first open and
the permission grants happen on the owner's Mac). Ports the job shape of the old `mac-release.yml`
([MIGRATION 5.2](../../docs/MIGRATION.md#52-cimac-release-workflow)) and the bundle assembly and checksum-verified
pinned download of the old `app/build.sh` ([MIGRATION 5.1](../../docs/MIGRATION.md#51-pr-41-releasemac-testable-m0-installable-build)),
without bun or the brain (the brain is cloud).

## Contract
- **Workflow** `.github/workflows/mac-artifact.yml`, separate from `ci.yml` (W1-B's file, not touched):
  `on: push (branches: w1/h-shell-onboarding), pull_request, workflow_dispatch`; `permissions: contents: read`; no
  `secrets.` reference; one job on `macos-26` with the `ci.yml` toolchain step (newest Xcode). Steps: build the bundle
  (`build-app.sh all`), installed-copy smoke check (`build-app.sh smoke`), upload with `actions/upload-artifact@v4`
  (artifact `Offload-mac-<shortsha>`, files `Offload-mac-<shortsha>.zip` and `INSTALL_AND_TEST.md`,
  `retention-days: 14`, `if-no-files-found: error`). The upload runs whenever the build step succeeded, even if the
  smoke check failed (a red check never hides a build); a final step fails the job if the smoke check failed. No long
  test step: `swift test` stays in `ci.yml`'s `mac` job. Actions pinned by tag as `ci.yml` does.
- **Script** `apps/mac/TestBuild/build-app.sh` (Bash 3.2, `set -euo pipefail`, never `set -x`), subcommands:
  - `info-plist <version> <build> <commit>`: prints the Info.plist (XML) for the test build: `CFBundleIdentifier`
    `ai.offload.mac.dev` (ROADMAP O2 dev id), `CFBundleExecutable` `Offload`, `CFBundleName`/`CFBundleDisplayName`
    `Offload`, `CFBundlePackageType` `APPL`, `CFBundleShortVersionString` `<version>`, `CFBundleVersion` `<build>`,
    `LSMinimumSystemVersion` `14.0`, `LSUIElement` true (menu bar app), `LSApplicationCategoryType`
    `public.app-category.productivity`, `NSHighResolutionCapable`, `NSPrincipalClass` `NSApplication`,
    `NSScreenCaptureUsageDescription` (DEPLOYMENT 3.2 sentence), `OffloadCommit` `<commit>` and
    `OffloadBuildKind` `test`. No Sparkle keys (updates are m3-03). Bad version (`MAJOR.MINOR.PATCH`), build (digits)
    or commit (7 to 40 hex) exits 2.
  - `version`: prints `apps/mac/TestBuild/VERSION`. `artifact-name <sha>`: prints `Offload-mac-<first 7>.zip`.
  - `assemble <binary> <out-dir>`: `<out-dir>/Offload.app/Contents/{Info.plist, PkgInfo, MacOS/Offload, Resources/}`
    plus any SwiftPM `*.bundle` beside the binary copied into `Resources/`. Version from `VERSION`, build from
    `OFFLOAD_BUILD_NUMBER` (default 1), commit from `OFFLOAD_COMMIT` (default `0000000`).
  - `sign <app>`: `${CODESIGN:-codesign} --force --sign - --timestamp=none <app>` (ad hoc only; Developer ID is m3-03).
  - `check <app>`: bundle structure, executable bit, Info.plist keys and values above, `codesign --verify --deep
    --strict` and `Signature=adhoc` in `codesign -dv`. One `FAIL` line per problem, exit 1.
  - `smoke <app>`: copies with `${DITTO:-ditto}` into a new temp folder, runs `check` on the copy, then runs
    `Contents/MacOS/Offload --version` under `env -i HOME=<tmp>/home PATH=/usr/bin:/bin:/usr/sbin:/sbin TMPDIR=<tmp>`
    with a 30 s limit; it must exit 0 and print `Offload <version> (<build>) <commit> ai.offload.mac.dev`.
  - `zip <app> <zip>`: `ditto -c -k --sequesterRsrc --keepParent`.
  - `fetch-pinned <url> <sha256> <out>`: downloads with `curl -fsSL --retry 3` and refuses (exit 1, file removed) on
    a checksum mismatch. Not used by this build (nothing is downloaded); kept for W1-B's Sparkle tools.
  - `all <out-dir>`: macOS only. `swift build -c release --product Offload`, assemble, sign, check, zip, copy the guide.
- **App flag** (`Sources/OffloadMacApp/`): `Offload --version` prints the line above from the bundle's Info.plist
  (or `Offload dev` from a `swift build` binary) and exits 0 before any window or TCC call. Not in `OffloadMac.swift`
  or `SelfCheck/` (m3-03's `--self-check` comes later).
- **Guide** `apps/mac/TestBuild/INSTALL_AND_TEST.md`: download from Actions artifacts, unzip, right-click Open
  (ad hoc), permissions, what onboarding shows, sending logs, uninstall and reset; links to DEPLOYMENT section 5 for
  the notarized build.
- No new dependency.

## Design note
- The script's subcommands split pure parts (plist, names, assembly, checks) from macOS-only tools, which are taken
  from `CODESIGN`, `DITTO` and `CURL` so the bun tests run every subcommand except `all` on Linux with fakes on `PATH`.
- Bundle id `ai.offload.mac.dev` is fixed in the script: a test build never takes the release id.
- The smoke check is the end-to-end proof on macOS; the bun suite proves the script's logic. `verify.sh` is bun only.
- Folder `apps/mac/TestBuild/` sits outside `apps/mac/Packaging/**` so W1-B can fold it into `bundle.sh` later.

## Red tests (write these first, run them, see them fail)
Folder `scripts/tests/m3-09-mac-test-build/`, `bun test`.

| Tag | Asserts |
|---|---|
| PLIST | dev bundle id, executable, version keys, macOS 14.0, LSUIElement true, category, usage string, commit; well-formed XML; no Sparkle keys; bad inputs exit 2; XML escaping |
| STAMP | VERSION is MAJOR.MINOR.PATCH; artifact name uses 7 chars of the sha; bad sha refused |
| ASSEMBLE | bundle layout, executable bit, PkgInfo, stamped Info.plist from env, SwiftPM bundles copied, missing binary fails |
| ADHOC | sign calls codesign ad hoc and never `--deep` when signing; check passes an ad hoc bundle; fails unsigned, wrong id, missing key |
| SMOKE | runs the copy under `env -i` with temp HOME; passes on the right line; fails on non-zero exit or wrong line; original untouched |
| PINNED | checksum match keeps the file; mismatch fails and removes it |
| ARTIFACT | workflow triggers, macos-26, no secrets, read-only permissions, upload before any test step and after build, zip name, retention 14, pinned actions, script is Bash 3.2 safe (no `set -x`, no `declare -A`, no `${x,,}`) |
| GUIDE | guide sections, right-click Open, links DEPLOYMENT section 5, no dry-run terms or em dashes |

## Out of scope
Developer ID signing, notarization, DMG, Sparkle, `--self-check` (m3-03); `ci.yml`; `apps/mac/Packaging/**`;
`docs/DEPLOYMENT.md` section 5; any Swift logic in `OffloadMac`.

## Verify
`bash slices/m3-09-mac-test-build/verify.sh` (bun suite, full suite, scope). The macOS proof is the
`mac-artifact` workflow run on GitHub (needs operator items O4 and O12).

## Scope changes
- Not in the ROADMAP task tables: added by the orchestrator so the owner can install the M3-C onboarding work before
  m3-03. `owns` lists only new paths.
- `apps/mac/Sources/OffloadMacApp/OffloadApp.swift` (m3-04's file, same branch): `@main` moves to a small entry that
  answers `--version` before the SwiftUI app starts.
- Accessibility has no Info.plist usage-description key that macOS shows, so only `NSScreenCaptureUsageDescription`
  is set, with the DEPLOYMENT 3.2 sentence (the docs' Info.plist table wins over the brief's "from ONBOARDING copy");
  the ONBOARDING screen 2 lines stay in the app.
- `docs/DEPLOYMENT.md` section 6.3 gains a `mac-artifact.yml` row (docs stay true). Section 5 is not edited.
- The old `--brain-check` smoke and bun bundling are dropped (MIGRATION 5.1); the smoke runs `--version`.
- The m3-04 `AppDelegate` sets `.regular` activation policy so the setup window has a Dock icon even with
  `LSUIElement`; left as is.
