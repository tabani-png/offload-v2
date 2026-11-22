# W1-H status (branch w1/h-shell-onboarding)

One line per slice step: slice | decision | tests | reviewer verdict.

- 2026-11-14 18:01 m3-04-mac-onboarding | built by Claude Opus 5.5 (session stalled waiting on its own background compile check; stopped by orchestrator) | 64 tests | verify-all green on Linux; review pending
- 2026-11-14 18:12 m3-09-mac-test-build | built by Claude Opus 5.5 | 35 tests | review pending
- 2026-11-14 18:13 m3-09-mac-test-build | built by Claude Opus 5.5 | 35 tests | review pending
- 2026-11-14 18:19 s2 | CI green on d1160cfc834e60435bd9ae47cdaf04da277e63e6 | runs: mac-artifact=success, ci=success, mac-artifact=success
- 2026-11-16 09:07 m3-04-mac-onboarding | review pass: 2 round(s) | 127 tests | reviewer: VERDICT: CHANGES
- 2026-11-19 16:33 m3-09-mac-test-build | review pass: 2 round(s) | 126 tests | reviewer: VERDICT: PASS
- 2026-11-19 16:37 s2b | CI green on 137b322aae4dc402d3013c994adf1dcde102bd54 | runs: mac-artifact=success, ci=success, mac-artifact=success
- 2026-11-20 14:47 m3-05-recordings-import | built by Claude Opus 5.5, 3 review round(s) | 112 tests | reviewer: VERDICT: CHANGES (logs: review3)
- 2026-11-20 15:03 s3 | CI green on acdb58e6cdffd20194bbc493c18726c61510c061 | runs: mac-artifact=success, ci=success, mac-artifact=success
- 2026-11-22 09:31 m3-04-mac-onboarding | wave2 review: last round 3 | 255 tests | reviewer: VERDICT: PASS (logs: review3)
- 2026-11-22 09:35 m3-05-recordings-import | wave2 review: last round 4 | 113 tests | reviewer: VERDICT: PASS (logs: review4)
- 2026-11-22 09:37 s4 | CI green on ae88dfd503b8c468cc6990b840a068025cd4b573 | runs: mac-artifact=success
- 2026-11-22 rebase | rebased onto origin/main 9565129 (m1-01..05, m1-02, m3-01, m3-03, m5-03 merged); one conflict (Package.swift) | verify-all green on Linux (SLICE_UPSTREAM=origin/main); m3-04, m3-05, m3-09 verify.sh pass (Swift parts skipped on Linux) | Swift unverified until the CI mac job runs

## CI notes

- **One executable (rebase 2026-11-22).** Main's `apps/mac/Package.swift` is kept unchanged: `OffloadMac` is the
  executable target (product `Offload`, Sparkle 2.10.1, rpath to `Contents/Frameworks`). This branch's
  `OffloadMacApp` target and `OffloadMac` library product are gone. The SwiftUI `App` now sits in
  `Sources/OffloadMac/App/OffloadApp.swift` without `@main`. m3-03's `OffloadEntry` (`OffloadMac.swift`) answers
  `--self-check`, then `--version` (m3-09), then calls `OffloadApp.main()`. m3-03's placeholder AppKit status item
  is replaced by `App/AppUpdates.swift`: Sparkle starts in the App's init (as Sparkle's SwiftUI setup does), and the
  menu bar item shows the lost-permission lines and "Check for Updates…" or the status line before Quit (`UpdateMenu`,
  tests `M304/ShellUpdatesTests.swift`). `UpdaterController.menuItem()` is now unused (m3-03's file, left as is).
  The app keeps m3-04's `.regular` activation policy (m3-03's placeholder used `.accessory`).
- **Test build links Sparkle.** `apps/mac/TestBuild/build-app.sh` now copies `Sparkle.framework` from beside the
  release binary into `Contents/Frameworks` and signs Autoupdate, Updater.app and the framework before the app (ad hoc,
  no hardened runtime, XPC services removed, never `--deep`). Without this, mac-artifact's `--version` smoke check
  would fail to load Sparkle. Not yet run on macOS.
- **m1-02 Swift contracts.** Main's m1-02 shipped TypeScript and JSON Schemas only; `OffloadContracts` is still the
  empty marker, so there is no Swift type to swap in. `OffloadImport/ImportWire.swift` stays hand-written. Checked
  against `packages/contracts/schemas/observation.schema.json`: keys, kinds, `source`/`import_id` and the limits (255,
  256, 512, 8000) match. The schema also caps `host` at 253, which the Mac side does not clip yet.
- **Local verify-all needs SLICE_UPSTREAM.** Without it, done slice m1-01's scope check walks main's own squashed W1
  merges (8f6ff2d..dc5bb7a) and fails, on origin/main too. CI sets `SLICE_UPSTREAM` (`HEAD^1` on pull requests).
  Locally: `SLICE_UPSTREAM=$(git rev-parse origin/main) bash scripts/verify-all.sh`. Main's DB tests also require a
  disposable database (`*_test`, or `COMMENT ON DATABASE ... IS 'offload:disposable'`).
- **SPECs.** m3-04, m3-05 and m3-09 `paths_in_scope` add `apps/mac/Sources/OffloadMac/App/**` and keep
  `apps/mac/Sources/OffloadMacApp/**` for their earlier commits. Each records the change under Scope changes.
- 2026-11-22 10:00 s5 | CI green on 440d46b0cfb6e1d65c163b57d266c50cefd164e4 | Mac artifact: Offload-mac-92ed60a | run https://github.com/tabani-png/offload-v2/actions/runs/45035606854
