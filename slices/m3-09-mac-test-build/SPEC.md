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
min_tests: 46
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
  `on: push (branches: w1/h-shell-onboarding), pull_request (paths `apps/mac/**` and the workflow file), workflow_dispatch`; `permissions: contents: read`; no
  `secrets.` reference; one job on `macos-26` with the `ci.yml` toolchain step (newest Xcode). Steps: build the bundle
  (`build-app.sh all`), installed-copy smoke check (`build-app.sh smoke`), upload with `actions/upload-artifact@v4`
  (artifact `Offload-mac-<shortsha>`, files `Offload-mac-<shortsha>.zip` and `INSTALL_AND_TEST.md`,
  `retention-days: 14`, `if-no-files-found: error`). The upload runs whenever the build step succeeded, even if the
  smoke check failed (a red check never hides a build); a final step fails the job if the smoke check failed. No long
  test step: `swift test` stays in `ci.yml`'s `mac` job. Actions pinned by tag as `ci.yml` does. The stamped commit
  is `GITHUB_SHA` (on a pull request, GitHub's merge commit, which is what was built); the run summary also names
  `github.event.pull_request.head.sha`, passed to the script only through `env`.
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
  - `assemble <binary> <out-dir>`: `<out-dir>/Offload.app/Contents/{Info.plist, PkgInfo, MacOS/Offload,
    Resources/THIRD_PARTY_NOTICES.txt (the repo NOTICE), Resources/LICENSE.txt}`. Version from `VERSION`, build from
    `OFFLOAD_BUILD_NUMBER` (default 1), commit from `OFFLOAD_COMMIT` (default `0000000`). A SwiftPM `*.bundle` beside
    the binary stops the build (exit 1, no bundle): SwiftPM's generated `Bundle.module` looks only at the `.app` root
    and the build machine's path, never `Contents/Resources`, and codesign refuses files at the `.app` root, so the
    installed app would crash. Resources need a `Bundle.main.resourceURL` lookup first; none exist today.
  - `sign <app>`: `${CODESIGN:-codesign} --force --sign - --timestamp=none <app>` (ad hoc only; Developer ID is m3-03).
  - `check <app>`: bundle structure, executable bit, Info.plist keys and values above, the DEPLOYMENT 3.1 rules (no
    Mach-O magic under `Resources/`, `THIRD_PARTY_NOTICES.txt` present, size at most `BUNDLE_MAX_MB`, default 50),
    `codesign --verify --deep --strict` and `Signature=adhoc` in `codesign -dv`. One `FAIL` line per problem, exit 1.
  - `smoke <app>`: copies with `${DITTO:-ditto}` into a new temp folder, runs `check` on the copy, then runs
    `Contents/MacOS/Offload --version` under `env -i HOME=<tmp>/home PATH=/usr/bin:/bin:/usr/sbin:/sbin TMPDIR=<tmp>`
    with a 30 s limit; it must exit 0 and print `Offload <version> (<build>) <commit> ai.offload.mac.dev`.
  - `zip <app> <zip>`: `ditto -c -k --sequesterRsrc --keepParent`.
  - `fetch-pinned <url> <sha256> <out>`: downloads with `curl -fsSL --retry 3` and refuses (exit 1, file removed) on
    a checksum mismatch. Not used by this build (nothing is downloaded); kept for W1-B's Sparkle tools.
  - `all <out-dir>`: macOS only. `swift build -c release --product Offload`, assemble, sign, check, zip, copy the guide.
- **App flag**: `Offload --version` prints the line above from the bundle's Info.plist (or `Offload dev` from a
  `swift build` binary, `unknown` for a missing `OffloadCommit`) and exits 0 before any window or TCC call. The line
  is `VersionLine.line(arguments:info:)` in `Sources/OffloadMac/Version/` (pure, tested by suite `M309`); the entry
  in `Sources/OffloadMacApp/` only prints it. Not in `OffloadMac.swift` or `SelfCheck/` (m3-03's `--self-check`).
- **Guide** `apps/mac/TestBuild/INSTALL_AND_TEST.md`: download from Actions artifacts (Safari and other browsers),
  first open (Open Anyway on macOS 15 and later, right-click Open on macOS 14), permissions, what this build does and
  does not do yet (no capture), sending logs, uninstall and reset (bundle-id folders of DEPLOYMENT 2); links to
  DEPLOYMENT section 5 for the notarized build.
- No new dependency.

## Design note
- The script's subcommands split pure parts (plist, names, assembly, checks) from macOS-only tools, which are taken
  from `CODESIGN`, `DITTO` and `CURL` so the bun tests run every subcommand except `all` on Linux with fakes on `PATH`.
- Bundle id `ai.offload.mac.dev` is fixed in the script: a test build never takes the release id.
- The smoke check is the end-to-end proof on macOS; the bun suite proves the script's logic; `M309` proves the
  version line. `verify.sh` runs the bun suite everywhere and `M309` on macOS (SKIPPED on Linux unless
  `REQUIRE_MAC=1`); CI's `mac` job runs `M309` inside its plain `swift test`.
- The info-plist values are constants or checked against digit and hex patterns, so `xml_escape` never sees a
  character to escape today. It stays as a guard for later free-text values and has no test of its own.
- Folder `apps/mac/TestBuild/` sits outside `apps/mac/Packaging/**` so W1-B can fold it into `bundle.sh` later.

## Red tests (write these first, run them, see them fail)
Folder `scripts/tests/m3-09-mac-test-build/`, `bun test` (`min_tests` counts these). Tag VERSION: Swift Testing,
`@Suite struct M309` in `apps/mac/Tests/OffloadMacTests/M309/` (macOS only).

| Tag | Asserts |
|---|---|
| PLIST | dev bundle id, executable, version keys, macOS 14.0, LSUIElement true, category, usage string, commit; well-formed XML; no Sparkle keys; bad inputs exit 2 |
| STAMP | VERSION is MAJOR.MINOR.PATCH; artifact name uses 7 chars of the sha; bad sha refused |
| ASSEMBLE | bundle layout, executable bit, PkgInfo, stamped Info.plist from env, LICENSE and notices, a SwiftPM resource bundle stops the build, missing binary fails |
| ADHOC | sign calls codesign ad hoc and never `--deep` when signing; check passes an ad hoc bundle; fails unsigned, wrong id, missing key, missing executable, Mach-O under Resources, missing notices, over the size budget |
| SMOKE | runs the copy under `env -i` with temp HOME (caller markers never reach the app); passes on the right line; fails on non-zero exit or wrong line; original untouched |
| PINNED | checksum match keeps the file; mismatch fails and removes it |
| ARTIFACT | workflow triggers, macos-26, no secrets, read-only permissions, upload before any test step and after build, zip name, retention 14, pinned actions, script is Bash 3.2 safe (no `set -x`, no `declare -A`, no `${x,,}`); pull request path filter; PR head named in the summary through env |
| GUIDE | guide sections, links DEPLOYMENT section 5, no dry-run terms or em dashes; bundle-id uninstall folders; Open Anyway first on macOS 15+; outer-zip browsers; no capture claims; PR merge commit |
| VERSION | bundled line; `Offload dev` without a version; `unknown` commit; no flag or flag only as program path gives nil (Swift) |

## Out of scope
Developer ID signing, notarization, DMG, Sparkle, `--self-check` (m3-03); `ci.yml`; `apps/mac/Packaging/**`;
`docs/DEPLOYMENT.md` section 5; Swift logic in `OffloadMac` beyond `Version/`.

## Verify
`bash slices/m3-09-mac-test-build/verify.sh` (bun suite, full suite, Swift suite `M309` on macOS, scope over this
slice's own commits only, as m3-04's verify.sh does on this stacked branch). The macOS proof is the `mac-artifact`
workflow run on GitHub (needs operator items O4 and O12).

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
- **Docs divergence, ad hoc build handed to the owner** (review 1 finding 2). DEPLOYMENT section 2 says dev builds are
  signed with a stable Apple Development identity, "never ad hoc, so grants persist across rebuilds"; section 3.6 says
  the owner's Mac runs a `.dev` build signed with his Apple Development identity, built locally; MIGRATION 5.2 drops
  "the ad hoc signature" and 5.1 rewrites the guide with "no Gatekeeper workaround". This slice hands the owner a CI
  build signed ad hoc, with a Gatekeeper workaround in the guide. Reason: CI has no Apple Development identity (O1 is
  not done; a personal-team identity belongs on the owner's Mac), and a workflow that runs on pull requests gets no
  signing secret (DEPLOYMENT 13 keeps them in the protected `release` environment; DEPLOYMENT 6.2 signs PR CI ad
  hoc). The cost is the one those docs avoid: grants may need turning off and on after each new download (the guide
  says so). It is a stopgap for trying the onboarding screens and retires when m3-03's Developer ID build lands, or
  earlier if the owner builds the `.dev` app locally with his Apple Development identity as DEPLOYMENT 3.6 describes.
  DEPLOYMENT 3.6 gains one line saying this.
- **Pull request path filter** (review 1 finding 6): `pull_request` runs only for `apps/mac/**` and the workflow file
  (macOS runner minutes, OQ-25). Pushes to the branch and manual runs always build. DEPLOYMENT 6.3's row says so.
- **XML escaping** (review 1 finding 5): the PLIST row no longer claims an escaping test; see the Design note.
- **Review 1 code changes**: `VersionLine` moves from the app target into the new, unowned folder
  `apps/mac/Sources/OffloadMac/Version/` with Swift suite `M309` (tag VERSION) under
  `apps/mac/Tests/OffloadMacTests/M309/`, both added to `owns` and `paths_in_scope`; `paths_out_of_scope` names the
  m3-03 and m3-04 folders instead of all of `apps/mac/Sources/OffloadMac/**` and `apps/mac/Tests/**`. m3-02's `owns`
  covers `apps/mac/**`, but m3-02 has not started (as m3-04 records). A SwiftPM resource bundle now stops the build
  instead of being copied (finding 11). The bundle carries `LICENSE.txt` and `THIRD_PARTY_NOTICES.txt`, and `check`
  applies the DEPLOYMENT 3.1 rules (finding 10). `min_tests` 24 → 46.
