# Status (w1/ui-analysis)

One line per slice step: slice | decision | tests | reviewer verdict.

- 2026-11-22 11:45 m3-10-mac-recordings-analysis | built by Claude Opus 5.5, 3 review round(s) | 153 tests | reviewer: VERDICT: CHANGES (logs: review3)

## CI notes
- 2026-11-22 CI run 1 (runs 45045944850 `mac`, 45045944844 `mac test build`): `swift build` failed with
  `invalid redeclaration of 'RecordingsScreen'` (Navigation/ShellViews.swift:114) and the follow-on argument errors at
  :68. m3-04's onboarding screen 11 is an internal `RecordingsScreen(model:spec:)` in the same module
  (Onboarding/OnboardingView.swift, out of scope). Fixed in m3-10: the shell's screen is `RecordingsShellScreen(app:)`
  (6ec0cc4 test, 7362a53 source). Not yet seen green: this is the first run that gets past the module build, so the
  test target compiles for the first time in the next run.
- For the stacked branches (w1/ui-today, w1/ui-weekly, w1/ui-builds): they carry the old `RecordingsScreen(app:)` in
  Navigation/ShellViews.swift and M310WiringTests.swift and fail the same way until they rebase onto this fix.
- `durable: workflow "sleeper" failed (Error)` in the `core` job is the expected log of the passing test
  "DURABLE: cancel stops a sleeping workflow before its next step"; the `core` job passed. No change.
- 2026-11-22 CI run 2 (run 45046523482, `mac`): the module built; the test target failed to compile with three Swift 6
  isolation errors, all in m3-10's own tests (fixed, b2cbe26 and dc9fefb):
  - M310BackendTests.swift:321 `reference to captured var 'patch' in concurrently-executing code`: `M310B.error` takes
    a `@Sendable` closure, which may not capture a `var`. The test now passes a `let` copy.
  - M310Review1Tests.swift:81 and :85 `main actor-isolated property 'insights'/'snapshot'` read from the nonisolated
    helpers `slackCounted`/`neverWatchCounted`. They now take the `InsightsSnapshot` (Sendable), which the
    `@MainActor` tests read and pass in.
  - M310Review2Tests.swift:107 and :109 `call to main actor-isolated static method 'importsOnThisMac(mode:)'` from a
    nonisolated test: `LocalAnalysis` is `@MainActor`, so its pure static rule was too. It is now `nonisolated`.
  Not yet seen green: region-isolation (SIL) diagnostics run only once a file type-checks, so the next run is the
  first to check those three files fully. `durable: workflow "sleeper"`/`"waiter-msg" failed (Error)` are again the
  expected logs of passing `core` tests; `core` passed.
- 2026-11-22 CI run 3 (run 45047413968, `mac`): everything compiled; 365 of 370 tests passed. Five m3-10 tests failed
  at runtime, all test setup in m3-10's own tests (fixed, bbcce9b; no source change, no expectation changed):
  - Four WIRING tests (M310WiringTests.swift:63 and :124, M310Review2Tests.swift:51, M310Review3Tests.swift:82):
    `startImport()` returned false, so nothing was imported (hence the empty snapshot at M310Review2Tests.swift:56).
    The tests set `ui.store.folder` after `OnDeviceRecordings.make`, but `RecordingsImportModel` reads the chosen
    folder once, when it is made (m3-05's rule, as M305's tests do it); the model kept the suggested `~/Desktop`,
    which does not exist, so the scan refused it. The tests now keep the folder first, then make the model.
  - FOLDERS (M310Review1Tests.swift:189): the suggestion `~/Documents/Captures` is a folder URL (trailing slash) and the
    expected URL was built without `isDirectory`, for a path that does not exist. The expected URL is now a folder
    URL; the comparison is unchanged.
  Not yet seen green: these four tests run the real importer through the model for the first time in the next run.
  `durable: workflow "sleeper" failed (Error)` is again the expected log of a passing `core` test; `core` passed.
- 2026-11-22 12:20 analysis | CI green on 8212c38ef699e99c83b1557d36b645fa555bcd09 | runs: mac-artifact=success, ci=success
