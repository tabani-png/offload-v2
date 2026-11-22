# Merging m3-10 to m3-13 onto m3-14 (for the orchestrator)

Refreshed 2026-11-22, review 6. Written from `git merge-tree` of this branch against `w1/ui-analysis` fc4574c,
`w1/ui-today` 158e89e, `w1/ui-weekly` debac36 and `w1/ui-builds` c070ab7. All four were rebased onto main, and the
merge base is now a97f748. The conflict lists after m3-10 come from an m3-10 merge resolved as below in a throwaway
worktree with rerere off (committed to no branch, then removed).

If the sibling tips move, re-run `git merge-tree --write-tree --name-only HEAD <branch>` before following this. It
writes nothing and records nothing. If you merge in a worktree instead, use `git -c rerere.enabled=false`.

None of this is a compile. Run the mac CI job on the merged branch.

## Order

1. This branch (`w1/mac-integration`, m3-14).
2. m3-10 (`w1/ui-analysis`).
3. m3-11 (`w1/ui-today`), m3-12 (`w1/ui-weekly`), m3-13 (`w1/ui-builds`), in any order. None of them contains m3-10's
   branch, but after step 2 each conflicts only in the file named in its section (m3-13 in none).

## m3-10 (`w1/ui-analysis`): three conflicting files

Everything else merges on its own, including:
- `OffloadMac.swift`, `App/AppUpdates.swift` and `Onboarding/Services.swift`, which end with this branch's text;
- m3-10's `AppWindowView` / `SettingsWindowView` swap and its menu item's sidebar hand-off in `App/OffloadApp.swift`;
- m3-10's init assignments and `insights.exclusionsChanged()` in `Shell/AppModel.swift`.

| File | Conflict | Resolution |
|---|---|---|
| `App/OffloadApp.swift` | One comment above `if app.recordings?.isOffered == true` | This branch's comment (the offer rule is the composition's `ImportOffer`). |
| `Shell/AppModel.swift`, stored properties | This branch's `launchPlan` vs m3-10's `navigation`, `backends`, `insights`, `onDeviceRecordings` | Keep both blocks. |
| `Shell/AppModel.swift`, init signature | `uploadsAvailable: Bool = true` vs m3-10's four parameters | This branch's line, then m3-10's: `currentNoticeVersion: String? = nil, uploadsAvailable: Bool = true, navigation: NavigationModel? = nil, backends: Backends = .local, insights: InsightsModel? = nil, onDeviceRecordings: OnDeviceRecordings? = nil`. |
| `Shell/AppModel.swift`, `live()` | This branch's comment vs m3-10's `AppModel.live()` | This branch's comment. Drop m3-10's `live()`; its wiring moves to `AppComposition.live()` (below). |
| `docs/ONBOARDING.md` section 8 | The offer-rule bullet | This branch's bullet (on this Mac past screen 2; through the uploader while sending). Keep m3-10's other new lines, which merge on their own. |

Then edit `Composition/AppComposition.swift` `live()`. There is no textual conflict, but without this edit nothing m3-10
needs reaches the app:

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

This gives m3-10:
- the capture's live events (`inputs.events`), so Today reads real data;
- the one Never watch list;
- an app model with `backends`, `insights` and `onDeviceRecordings`;
- `startLocalAnalysis` after launch.

The composition then applies its one offer rule, `ImportOffer`, over the `RecordingsOffer` rule that m3-10's
`wireRecordingsOffer()` set.

### Decisions for m3-10's SPEC (not drop-in changes)

- **Masker and ledger on the import path.** After the merge, the import the owner uses is m3-10's `OnDeviceRecordings`.
  - It masks with `InterimTextMasker(key:names:appNames:)`, which adds person-name masking through a NaturalLanguage
    finder (m3-10 SPEC, Known limits and the MASK tests) that m3-02's `TextMasker` does not have.
  - Its `ledger` is typed `FileRecordingLedger`, and `discardUnfinished` takes that type.
  - Swapping in m3-14's `ImportMaskerAdapter` and `ResettableImportLedger` (both offered in `AnalysisInputs`) would
    drop that name masking and change those types.
  - So the choice belongs to m3-10's SPEC: keep the interim masker, or add the finder to the real one. Either way,
    "Start fresh" should also clear m3-10's ledger.
- **Writes before consent.** The analysis hook runs at every launch. m3-10's `LocalAnalysis.live` →
  `OnDeviceRecordings.make` then creates its folder (`OnDeviceFiles.ensureFolder`) and its `LocalPseudonymKey` file
  before screen 1. Nothing leaves the Mac, but it differs from m3-14's capture, which writes nothing before screen 2.
  Record it in m3-10's SPEC, or make those two writes lazy, so they happen at the first import.

## m3-11 (`w1/ui-today`), after m3-10

| File | Conflict | Resolution |
|---|---|---|
| `App/OffloadApp.swift` | `MenuBarOpener.body`: this branch's mode-lines block vs m3-11's `TodayMenuLine(app: app)` | Keep both: the mode-lines block (`let lines = modeLines()`, `ForEach`, `Divider`) first, then `TodayMenuLine(app: app)`, then `MenuBarContent(...)`. |

## m3-12 (`w1/ui-weekly`), after m3-10

| File | Conflict | Resolution |
|---|---|---|
| `Shell/AppModel.swift`, stored properties | `launchPlan` vs m3-12's `lazy var weeklyReview` | Keep both. |
| `Shell/AppModel.swift`, `live()` | This branch's comment vs m3-12's copy of `AppModel.live()` | This branch's comment; drop `live()`. Move its one new line, `app.weeklyReview.start()`, into the same `afterLaunch` in `AppComposition.live()`: `afterLaunch: { app in app.startLocalAnalysis(rules: local.rules); app.weeklyReview.start() }`. |

m3-12's `.modifier(WeeklyReviewWindowOpener(hub: app.weeklyReview))` on `MenuBarLabel(app: app)` merges on its own.
Keep it there. Add nothing to `AppWindowView`: the menu bar label always exists, while the main window is usually closed
when the notification is clicked.

## m3-13 (`w1/ui-builds`), after m3-10

No conflict.

## After the merges

```
bash scripts/verify-all.sh   # Linux: lints, bun suite, slice scopes
# macOS (the mac CI job): swift build && swift test (M302, M303, M304, M305, M309, M310 to M314)
```

These stay true after the steps above:
- M314's ENTRY tests: one `@main`, AppModel built only in `Composition/`, other modules' types qualified in
  `Composition/`.
- M310's tests build `AppModel(...)` with labelled arguments that skip the defaulted ones (`sampleWeek:`, then
  `backends:`, `insights:`, `onDeviceRecordings:`), so they compile with m3-14's `uploadsAvailable` placed before
  m3-10's parameters.
