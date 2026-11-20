import Combine
import Foundation
import Testing
@testable import OffloadImport
@testable import OffloadMac

// Review 2 (logs/m3-05-recordings-import.review2.md): app exclusions by name, overlapping Imports on screen 11, no
// folder read while the import is not offered, back-to-back imports, redraws, a refusal shown once, throttled
// VoiceOver announcements, and Never watch changes inside one run of screenshots.
extension M305 {
  static func ingest(_ script: M305Script, rules: [ImportExclusionRule], keyframes: FakeKeyframes? = nil) throws -> IngestResult {
    try M305.ingestor([script], keyframes: keyframes).ingest(FakeRecording(script), startedAt: M305Clock.now.addingTimeInterval(-600),
                                                             importID: "imp", exclusions: rules)
  }

  // MARK: EXCLUDE (finding 1)

  @Test("EXCLUDE: m3-04's Photos chip applies to a recording of Photos: focus kept, no text, no keyframe")
  func photosChipOnRecording() throws {
    let store = NeverWatchStore()
    let photos = try #require(NeverWatchChip.optional.first { $0.id == "photos" })
    store.add(photos.exclusions)
    let rules = NeverWatchImportExclusions(source: store).currentRules()
    let script = M305.oneScene("photos", m305Screen(app: "Photos", menus: "File Edit Image View Window Help", body: "Holiday album"))
    let keyframes = FakeKeyframes()
    let r = try M305.ingest(script, rules: rules, keyframes: keyframes)
    #expect(M305.of(.textSnapshot, r).isEmpty)
    #expect(keyframes.all.isEmpty)
    #expect(M305.of(.focus, r).map(\.appName) == ["Photos"])
  }

  @Test("EXCLUDE: an app the person named on screen 9 applies to a recording by its display name, though it is in no table")
  func userAppByDisplayName() throws {
    let store = NeverWatchStore()
    store.add([Exclusion(kind: .bundleID, value: "org.example.ledger")])
    let rules = NeverWatchImportExclusions(source: store, appName: { $0 == "org.example.ledger" ? "Acme Ledger" : nil }).currentRules()
    #expect(rules.contains(ImportExclusionRule(kind: .bundleID, value: "org.example.ledger", appName: "Acme Ledger")))
    let script = M305.oneScene("ledger", m305Screen(app: "Acme Ledger", menus: "File Edit View", body: "Balance owed"))
    let r = try M305.ingest(script, rules: rules)
    #expect(M305.of(.textSnapshot, r).isEmpty)
    #expect(M305.of(.focus, r).map(\.appName) == ["Acme Ledger"])
    // The name matches whatever its case; another app with no rule is read.
    #expect(ImportExclusions.isExcluded(bundleID: "recording.acme-ledger", appName: "ACME LEDGER", title: nil, host: nil, rules: rules))
    #expect(!ImportExclusions.isExcluded(bundleID: "recording.acme-notes", appName: "Acme Notes", title: nil, host: nil, rules: rules))
  }

  @Test("EXCLUDE: a built-in banking app (MoneyMoney) recorded with its menu bar gets no text")
  func builtInBankingApp() throws {
    let script = M305.oneScene("money", m305Screen(app: "MoneyMoney", menus: "File Edit View Window", body: "Account balance"))
    let r = try M305.ingest(script, rules: [])
    #expect(M305.of(.textSnapshot, r).isEmpty)
    #expect(M305.of(.focus, r).map(\.appName) == ["MoneyMoney"])
    for name in ["Banktivity", "Quicken", "Microsoft Authenticator", "Yubico Authenticator"] {
      #expect(ImportExclusions.isExcluded(bundleID: MenuBarApp.bundleID(for: name), appName: name, title: nil, host: nil, rules: []), "\(name)")
    }
  }

  @Test("EXCLUDE: a screenwatch row of an excluded app keeps its name only")
  func screenwatchRowOfExcludedApp() throws {
    let store = NeverWatchStore()
    store.add([Exclusion(kind: .bundleID, value: "com.apple.Photos")])
    let rules = NeverWatchImportExclusions(source: store).currentRules()
    let rows = [ScreenwatchRow(t: "09-00-00", ts: M305Clock.date(2026, 9, 1, 9), app: "Photos", window: "Holiday album",
                               url: "https://photos.example.com/album", img: true)]
    let obs = ScreenwatchReader.observations(rows: rows, importID: "imp", masker: FakeMasker(), exclusions: rules, ids: ULIDGenerator())
    let focus = try #require(obs.first { $0.kind == .focus })
    #expect(focus.appName == "Photos")
    #expect(focus.title == nil)
    #expect(focus.host == nil)
  }

  // MARK: SCREEN (findings 2, 3, 4, 5, 6)

  @Test("SCREEN: two Imports, or Import then Skip, while the folder is read end on screen 12, never skip it")
  @MainActor func overlappingImportsStayOnScreen12() async {
    for second in [OnboardingAction.importRecordings, .skip] {
      let folder = M305Files.folder("Desktop")
      M305Files.put(folder, "Screen Recording 2026-11-13 at 9.41.07 AM.mov")
      let ui = M305UI()
      let recordings = ui.model(importer: M305Importer(), suggested: folder)
      let model = await M305.onboardingAtRecordings(recordings)
      let first = Task { await model.perform(.importRecordings) }
      let other = Task { await model.perform(second) }
      await first.value
      await other.value
      #expect(model.flow.screen == .handsOn, "\(second)")
      await recordings.waitForImport()
      M305Files.remove(folder)
    }
  }

  @Test("SCREEN: while the import is not offered, refresh reads no folder (a restored Settings window in Local mode)")
  @MainActor func noReadWhenNotOffered() async {
    let suggested = M305Files.folder("Desktop")
    defer { M305Files.remove(suggested) }
    M305Files.put(suggested, "Screen Recording 2026-11-05 at 9.00.00 AM.mov")
    let reads = M305Counter()
    let ui = M305UI()
    let model = ui.model(importer: nil, suggested: suggested, offered: false, durations: { _ in
      reads.bump()
      return 600
    })
    await model.refresh()
    #expect(reads.count == 0)
    #expect(model.summary == nil)
    #expect(model.refusal == nil)
  }

  @Test("SCREEN: a second import right after the first has finished is the one waitForImport waits for")
  @MainActor func backToBackImports() async {
    let folder = M305Files.folder("Desktop")
    defer { M305Files.remove(folder) }
    M305Files.put(folder, "Screen Recording 2026-11-13 at 9.41.07 AM.mov")
    let ui = M305UI()
    let model = ui.model(importer: M305Importer(), suggested: folder)
    let started = await model.startImport()
    #expect(started)
    // Waits for the first import's progress to be applied in full (no timing loop).
    await model.waitForImport()
    #expect(!model.isImporting)
    M305Files.put(folder, "Screen Recording 2026-11-14 at 9.41.07 AM.mov")
    let again = await model.startImport()
    #expect(again)
    await model.waitForImport()
    #expect(model.imports.count == 2)
  }

  @Test("SCREEN: every onboarding action tells the recordings model to redraw (Settings follows sending)")
  @MainActor func onboardingRedrawsRecordings() async {
    let ui = M305UI()
    let recordings = ui.model(importer: nil, suggested: URL(fileURLWithPath: "/nowhere"))
    let redraws = M305Counter()
    let watching = recordings.objectWillChange.sink { _ in redraws.bump() }
    let model = await M305.onboardingAtRecordings(recordings)
    #expect(model.flow.screen == .recordings)
    #expect(redraws.count >= M304Path.toWhatLeaves.count)
    watching.cancel()
  }

  @Test("SCREEN: a refused folder's sentence is shown once on screen 11, and Choose folder… clears the old line")
  @MainActor func refusalShownOnce() async {
    let empty = M305Files.folder("Stuff")
    defer { M305Files.remove(empty) }
    M305Files.put(empty, "notes.txt")
    let ui = M305UI()
    let recordings = ui.model(importer: M305Importer(), suggested: empty)
    let model = await M305.onboardingAtRecordings(recordings)
    await model.perform(.importRecordings)
    #expect(model.flow.screen == .recordings)
    #expect(recordings.refusal?.hasPrefix("No screen recordings found in Stuff.") == true)
    #expect(model.notice == nil)   // the screen's body already shows the refusal

    let ready = M305Files.folder("Recordings")
    defer { M305Files.remove(ready) }
    M305Files.put(ready, "Screen Recording 2026-11-13 at 9.41.07 AM.mov")
    let notReady = ui.model(importer: nil, suggested: ready)
    let screen = await M305.onboardingAtRecordings(notReady)
    await screen.perform(.importRecordings)
    #expect(screen.notice == RecordingsCopy.notReady)
    ui.picker.answer = ready
    await screen.chooseRecordingsFolder()
    #expect(screen.notice == nil)
    #expect(notReady.folder == ready)
  }

  @Test("SCREEN: VoiceOver hears the start, about every tenth of the files, warnings and the end, not every file")
  @MainActor func announcementsAreThrottled() {
    let ui = M305UI()
    let model = ui.model(importer: nil, suggested: URL(fileURLWithPath: "/nowhere"))
    model.apply(.started(.screenshots, files: 100))
    for i in 1...100 { model.apply(.reading(file: i, of: 100)) }
    #expect(model.announcements == 11)
    model.apply(.warning(.unreadable(file: "a.png")))
    #expect(model.announcements == 12)
    #expect(model.announcement == "Couldn't read a.png.")
    let report = ImportReport(space: nil, filesRead: 99, skipped: 0, failed: 1, stillWriting: 0, moments: 1284,
                              observations: 0, firstDay: nil, lastDay: nil)
    model.apply(.finished(report))
    #expect(model.announcements == 13)
    #expect(model.announcement == "done, 1,284 moments read")
  }

  // MARK: PROGRESS (finding 4)

  @Test("PROGRESS: a Never watch entry added inside one run of screenshots applies from the next screenshot")
  func exclusionsReloadPerScreenshot() async throws {
    let src = M305Files.folder("Shots")
    defer { M305Files.remove(src) }
    let names = ["Screenshot 2026-10-20 at 10.10.10 AM.png", "Screenshot 2026-10-20 at 10.10.15 AM.png"]
    for n in names { M305Files.put(src, n) }
    let store = NeverWatchStore()
    var fakes = M305Importer()
    fakes.exclusions = NeverWatchImportExclusions(source: store)
    fakes.imageLines[names[0]] = m305Screen(app: "Numbers", body: "Sheet one")
    fakes.imageLines[names[1]] = m305Screen(app: "Numbers", body: "Sheet two")
    let log = ProgressLog()
    await fakes.importer().run(folder: src) { p in
      log.add(p)
      if case .reading(file: 2, of: _) = p { store.add([Exclusion(kind: .bundleID, value: "com.apple.iWork.Numbers")]) }
    }
    let space = try #require(log.report?.space)
    let texts = fakes.sink.observations(in: space.id).filter { $0.kind == .textSnapshot }.compactMap(\.text)
    #expect(texts == ["Sheet one"])
  }
}
