# Merging m3-10 to m3-13 onto m3-14 (for the orchestrator)

Written from `git merge-tree` against `w1/ui-analysis` 0e7fd00, `w1/ui-today` 30243fe, `w1/ui-weekly` a1675c9 and
`w1/ui-builds` 8911059 (2026-11-22), and from a rehearsal of the m3-10 merge in a throwaway worktree (not committed to
any branch). After the rehearsal, these checks passed on the merged tree:

- a structural check of all 201 Swift files: strings and comments stripped, braces, parens and brackets balanced;
- no type declared twice in OffloadMac;
- one `@main`;
- no `AppModel(` / `AppUpdates(` / `CaptureRuntime(` / `UploadRuntime(` outside `Composition/`;
- no unqualified `HTTPTransport`, `URLSessionTransport`, `JCS`, `JSONValue` or `Figure` in a file that also imports
  OffloadUploader or OffloadContracts.

None of this is a compile. The mac CI job on the merged branch is the check that counts.

Disable rerere for the merge (`git -c rerere.enabled=false merge ...`) unless you mean to record these resolutions.

## Order

1. This branch (`w1/mac-integration`, m3-14).
2. m3-10 (`w1/ui-analysis`).
3. m3-11, m3-12, m3-13. These three carry an older copy of m3-10, so after step 2 they also conflict inside m3-10's own
   files: `Analysis/`, `Navigation/`, `OnDevice/`, `M310/` tests, m3-10's SPEC, `STATUS-ui-analysis.md`. Rebase each
   onto the current `w1/ui-analysis` first (their owners' call), or take the `w1/ui-analysis` side in those files.
   The m3-14 part of their conflicts is only the two hook files and ONBOARDING (below).

## m3-10 (`w1/ui-analysis`): conflicting files and their resolution

| File | Resolution |
|---|---|
| `apps/mac/Sources/OffloadMac/OffloadMac.swift` | **This branch.** m3-10's side is the pre-rebase PR #7 entry (`OffloadMacTodo`, inline `--version`). |
| `App/AppUpdates.swift` | **This branch** (`init(capture:)`). m3-10's side builds `CaptureNotStarted()`. |
| `Onboarding/Services.swift` | **This branch** (comments only). |
| `App/OffloadApp.swift` | **This branch**, then three edits from m3-10 (see below). |
| `Shell/AppModel.swift` | **This branch**, plus m3-10's additions (see below); drop m3-10's `AppModel.live()`. |
| `Composition/AppComposition.swift` | No textual conflict. Edit `live()` (see below), or nothing m3-10 needs reaches the app. |
| `apps/mac/README.md`, `docs/ARCHITECTURE.md`, `docs/GLOSSARY.md`, `docs/SECURITY_PRIVACY.md`, `STATUS.md` | Keep both sides' text. In `docs/ONBOARDING.md` section 8, keep this branch's offer rule (on this Mac past screen 2; through the uploader while sending) and m3-10's other lines. |

`App/OffloadApp.swift`: keep this branch's `OffloadApp.init` (the composition root, `updates`, `modeLines`) and its
`MenuBarOpener` (mode lines as `Text`, optional updates). Then:

- In the `"main"` window, replace `MainWindowView(app: app)` with `AppWindowView(app: app)` (m3-10's sidebar).
- In the `"settings"` window, replace `OffloadSettingsView(app: app)` with `SettingsWindowView(app: app)`.
- In `MenuBarOpener`, inside `if app.recordings?.isOffered == true { Button(RecordingsCopy.menuItem) { ... } }`, take
  m3-10's body:

```swift
if app.route == .today {
  app.navigation.selection = .recordings
  openWindow(id: "main")
} else {
  app.navigation.requestSettings()
  openWindow(id: "settings")
}
```

`Shell/AppModel.swift`: keep this branch's file. It keeps `launchPlan`, the LaunchPlan block, `uploadsAvailable`,
`onStartFresh`, and has no `live()`. Add from m3-10:

- the four stored properties `navigation`, `backends`, `insights`, `onDeviceRecordings`;
- the init parameters `navigation: NavigationModel? = nil, backends: Backends = .local, insights: InsightsModel? = nil,
  onDeviceRecordings: OnDeviceRecordings? = nil`, after `uploadsAvailable: Bool = true`, and their four assignments
  before `let onboarding = ...`;
- `insights.exclusionsChanged()` at the end of `dontWatch(_:)`.

`Composition/AppComposition.swift` `live()`, as rehearsed:

```swift
public static func live(arguments: [String] = ProcessInfo.processInfo.arguments,
                        seams given: CompositionSeams? = nil) -> AppComposition {
  // m3-10: the screens' flag (member token) and the local analysis, plugged in through the analysis hook.
  let backends = Backends.make(mode: BackendMode.resolve(defaults: .standard, tokens: NoMemberToken()))
  let seams = given ?? CompositionSeams(analysis: { inputs in
    let local = LocalAnalysis.live(neverWatch: inputs.neverWatch, events: inputs.events, mode: backends.mode)
    return AnalysisPlug(
      recordings: local.onDevice?.model, onDeviceImport: local.onDevice != nil,
      makeApp: { parts in
        AppModel(options: parts.options, bundlePath: parts.bundlePath, bufferReadable: parts.bufferReadable,
                 store: parts.store, services: parts.services, probe: parts.probe, events: parts.events,
                 sampleWeek: parts.sampleWeek, currentNoticeVersion: parts.currentNoticeVersion,
                 uploadsAvailable: parts.uploadsAvailable, backends: backends, insights: local.insights,
                 onDeviceRecordings: local.onDevice)
      },
      afterLaunch: { app in app.startLocalAnalysis(rules: local.rules) })
  })
  // ... the rest of live() as on this branch, passing `seams` to AppComposition(environment:seams:...)
}
```

This gives m3-10 the capture's live events (`inputs.events`, so Today reads real data) and the one Never watch list.
Its app model gets `backends`, `insights` and `onDeviceRecordings`, and `startLocalAnalysis` runs after launch. The
composition then applies its one offer rule, `ImportOffer`, over the `RecordingsOffer` rule that m3-10's
`wireRecordingsOffer()` set.

### The import path after the merge (needs a small change in m3-10's code)

The import the owner uses after the merge is m3-10's `OnDeviceRecordings`. As built, it uses its own
`InterimTextMasker`, its own pseudonym key file and its own `FileRecordingLedger`. To keep reviews 4 and 5 true on
that path (the real masker with the capture's key, no import space without the key, a ledger "Start fresh" resets):

- `OnDeviceRecordings.make` takes `masker: ImportMaskerAdapter?` and `ledger: (any RecordingLedger)?`.
  - When `masker` is given, it uses that masker and wraps its sink in `MaskerCheckedSink(sink:masker:)`.
  - When `ledger` is given, it uses that ledger instead of `FileRecordingLedger(file: paths.ledger)`.
- `LocalAnalysis.live` passes `inputs.importMasker` and `inputs.importLedger` (add the two parameters).
- m3-10's own tests keep their fakes (both parameters default to nil).

If m3-10 keeps the interim masker for its person-name finder, record that in m3-10's SPEC. In that case "Start fresh"
also has to clear m3-10's ledger.

## m3-11 (`w1/ui-today`)

After m3-10 is in, the m3-14 parts:

- `App/OffloadApp.swift`: in `MenuBarOpener.body`, add `TodayMenuLine(app: app)` after this branch's mode-lines block
  (`ForEach(lines ...) / Divider()`) and before `MenuBarContent(...)`.
- `Shell/AppModel.swift`: m3-11 adds nothing beyond m3-10's lines. Keep the merged file.
- `docs/ONBOARDING.md`: keep both.

## m3-12 (`w1/ui-weekly`)

- `Shell/AppModel.swift`: add m3-12's `public private(set) lazy var weeklyReview: WeeklyReviewHub = WeeklyReviewHub(app: self)`.
- `Composition/AppComposition.swift` `live()`: m3-12's `app.weeklyReview.start()` was in the dropped `AppModel.live()`.
  Put it in the same `afterLaunch`: `afterLaunch: { app in app.startLocalAnalysis(rules: local.rules); app.weeklyReview.start() }`.
- `App/OffloadApp.swift`: add `.modifier(WeeklyReviewWindowOpener(hub: app.weeklyReview))` to `AppWindowView(app: app)`
  in the `"main"` window.
- `docs/ONBOARDING.md`: keep both.

## m3-13 (`w1/ui-builds`)

- No m3-14 change beyond m3-10's. `App/OffloadApp.swift` and `Shell/AppModel.swift` conflict only on m3-10's own lines,
  so keep the merged file.

## After each merge

```
bash scripts/verify-all.sh                       # Linux: lints, bun suite, slice scopes
python3 -I <structural check> apps/mac/**/*.swift  # optional; the m3-14 author's script, any brace checker works
# macOS (the mac CI job): swift build && swift test (M302, M303, M304, M305, M309, M310..M314)
```

M314's ENTRY tests stay true after these steps: one `@main`, AppModel built only in `Composition/`, other modules'
types qualified in `Composition/`. M310's tests build `AppModel(...)` directly with their own arguments, and those
still compile, because m3-14's `uploadsAvailable` comes before m3-10's parameters and is defaulted.
