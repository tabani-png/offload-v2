import Foundation
import Testing
@testable import OffloadImport
@testable import OffloadMac

// Screen 11 and Settings, Recordings (ONBOARDING section 8): the model behind both, the onboarding hook and the copy
// (PR #44 S34RecordingsAppTests, wip/s34-mac PILL and its no-removed-terms test).
extension M305 {
  /// Screen 11 over m3-04's fakes, with this slice's recordings model in the services.
  @MainActor static func onboardingAtRecordings(_ recordings: RecordingsImportModel) async -> OnboardingModel {
    let fakes = M304Services()
    var services = fakes.services
    services.recordings = recordings
    let model = OnboardingModel(store: fakes.store, services: services)
    for a in M304Path.toWhatLeaves + [.startSending(noticeVersion: "1"), .skip, .skip, .skip, .skip, .skip] { await model.perform(a) }
    return model
  }

  // MARK: SCREEN

  @Test("SCREEN: Import on screen 11 starts the import in the background and setup goes on to screen 12")
  @MainActor func importStartsAndSetupGoesOn() async throws {
    let folder = M305Files.folder("Desktop")
    defer { M305Files.remove(folder) }
    M305Files.put(folder, "Screen Recording 2026-11-13 at 9.41.07 AM.mov")
    let ui = M305UI()
    let fakes = M305Importer()
    let recordings = ui.model(importer: fakes, suggested: folder)
    let model = await M305.onboardingAtRecordings(recordings)
    #expect(model.flow.screen == .recordings)
    await model.perform(.importRecordings)
    #expect(model.flow.screen == .handsOn)
    #expect(model.notice == nil)
    #expect(ui.panel.shown == 1)
    await recordings.waitForImport()
    guard case .done(let report) = recordings.phase else { Issue.record("not done: \(recordings.phase)"); return }
    #expect(report.filesRead == 1)
    #expect(recordings.imports.count == 1)
    #expect(recordings.imports.first?.folderName == "Desktop")
    #expect(ui.store.imports.count == 1)
  }

  @Test("SCREEN: in this build (no on-device text reading yet) Import says so, stays on screen 11 and reads nothing")
  @MainActor func notReadyStays() async {
    let folder = M305Files.folder("Desktop")
    defer { M305Files.remove(folder) }
    M305Files.put(folder, "Screen Recording 2026-11-13 at 9.41.07 AM.mov")
    let ui = M305UI()
    let recordings = ui.model(importer: nil, suggested: folder)
    #expect(!recordings.canImport)
    let model = await M305.onboardingAtRecordings(recordings)
    await model.perform(.importRecordings)
    #expect(model.flow.screen == .recordings)
    #expect(model.notice == RecordingsCopy.notReady)
    #expect(ui.panel.shown == 0)
    #expect(recordings.phase == .idle)
    #expect(recordings.imports.isEmpty)
  }

  @Test("SCREEN: the folder shown is the one last chosen, else where macOS saves recordings, with its summary")
  @MainActor func folderAndSummary() async {
    let suggested = M305Files.folder("Desktop")
    defer { M305Files.remove(suggested) }
    M305Files.put(suggested, "Screen Recording 2026-11-05 at 9.00.00 AM.mov")
    M305Files.put(suggested, "Screen Recording 2026-11-11 at 9.00.00 AM.mov")
    let ui = M305UI()
    let model = ui.model(importer: nil, suggested: suggested)
    #expect(model.folder == suggested)
    await model.refresh()
    #expect(model.summaryItems == ["2 files", ".mov", "20 m", "Nov 5 to 11"])
    let other = M305Files.folder("Movies")
    defer { M305Files.remove(other) }
    ui.store.folder = other
    #expect(ui.model(importer: nil, suggested: suggested).folder == other)
  }

  @Test("SCREEN: Choose folder… asks for a folder, keeps it and reads its summary; a cancel changes nothing")
  @MainActor func chooseFolder() async {
    let suggested = M305Files.folder("Desktop")
    defer { M305Files.remove(suggested) }
    let picked = M305Files.folder("Recordings")
    defer { M305Files.remove(picked) }
    M305Files.put(picked, "Screen Recording 2026-11-13 at 9.41.07 AM.mov")
    let ui = M305UI()
    let model = ui.model(importer: nil, suggested: suggested)
    ui.picker.answer = nil
    await model.chooseFolder()
    #expect(model.folder == suggested)
    ui.picker.answer = picked
    await model.chooseFolder()
    #expect(ui.picker.asked == [suggested, suggested])
    #expect(model.folder == picked)
    #expect(ui.store.folder == picked)
    #expect(model.summaryItems.first == "1 file")
  }

  @Test("SCREEN: a refused folder says why on the screen and nothing starts")
  @MainActor func refusedFolder() async {
    let empty = M305Files.folder("Stuff")
    defer { M305Files.remove(empty) }
    M305Files.put(empty, "notes.txt")
    let ui = M305UI()
    let model = ui.model(importer: M305Importer(), suggested: empty)
    await model.refresh()
    #expect(model.refusal?.hasPrefix("No screen recordings found in Stuff.") == true)
    #expect(!(await model.startImport()))
    #expect(model.notice == model.refusal)
    #expect(ui.panel.shown == 0)
  }

  @Test("SCREEN: PILL, Settings shows each import as Recordings from <folder> and its days, with Remove imported data")
  @MainActor func pill() async throws {
    let space = ImportSpace(id: "8d0f2f4e-0000-4000-8000-000000000001", sourceKind: .videos)
    let record = ImportRecord(space: space, folderName: "Desktop", first: M305Clock.date(2026, 11, 5, 9),
                              last: M305Clock.date(2026, 11, 11, 17), moments: 1284, createdAt: M305Clock.now)
    #expect(RecordingsCopy.pill(record, timeZone: M305Clock.utc) == ["Recordings from Desktop", "Nov 5 to 11", "1,284 moments read"])
    #expect(RecordingsCopy.removeImported == "Remove imported data")
    let ui = M305UI()
    ui.store.imports = [record]
    let model = ui.model(importer: nil, suggested: URL(fileURLWithPath: "/nowhere"))
    #expect(model.imports == [record])
    // Without a sink (this build) nothing was ever sent, so removing forgets it on this Mac only.
    await model.remove(record)
    #expect(model.imports.isEmpty)
    #expect(ui.store.imports.isEmpty)
  }

  @Test("SCREEN: the progress panel's line follows the import: reading file n of N, then done and moments read")
  @MainActor func progressLines() {
    let ui = M305UI()
    let model = ui.model(importer: nil, suggested: URL(fileURLWithPath: "/nowhere"))
    model.apply(.started(.videos, files: 12))
    model.apply(.reading(file: 3, of: 12))
    #expect(model.progressItems == ["reading file 3 of 12"])
    model.apply(.warning(.unreadable(file: "broken.mov")))
    #expect(model.warnings == ["Couldn't read broken.mov."])
    let report = ImportReport(space: ImportSpace(id: "8d0f2f4e-0000-4000-8000-000000000001", sourceKind: .videos),
                              filesRead: 11, skipped: 0, failed: 1, stillWriting: 0, moments: 1284, observations: 3000,
                              firstDay: M305Clock.date(2026, 11, 5), lastDay: M305Clock.date(2026, 11, 11))
    model.apply(.finished(report))
    #expect(model.progressItems == ["done", "1,284 moments read"])
    let none = ImportReport(space: nil, filesRead: 0, skipped: 3, failed: 0, stillWriting: 0, moments: 0, observations: 0,
                            firstDay: nil, lastDay: nil)
    model.apply(.finished(none))
    #expect(model.progressItems == ["No new recordings."])
  }

  @Test("SCREEN: the user's Never watch list reaches the importer through the app's adapter")
  @MainActor func adapterKinds() {
    let store = NeverWatchStore(builtIn: [Exclusion(kind: .titleContains, value: "Incognito", source: .builtin)])
    store.add([Exclusion(kind: .host, value: "mail.google.com"), Exclusion(kind: .bundleID, value: "com.tinyspeck.slackmacgap")])
    let rules = NeverWatchImportExclusions(source: store).currentRules()
    #expect(rules == [ImportExclusionRule(kind: .titleContains, value: "Incognito"),
                      ImportExclusionRule(kind: .host, value: "mail.google.com"),
                      ImportExclusionRule(kind: .bundleID, value: "com.tinyspeck.slackmacgap")])
  }

  // MARK: Review 1

  @Test("SCREEN: building the model reads no folder (no Desktop access at launch); the screen's refresh does, off the main actor")
  @MainActor func noScanAtLaunch() async {
    let suggested = M305Files.folder("Desktop")
    defer { M305Files.remove(suggested) }
    M305Files.put(suggested, "Screen Recording 2026-11-05 at 9.00.00 AM.mov")
    let reads = M305Counter()
    let ui = M305UI()
    let model = ui.model(importer: nil, suggested: suggested, durations: { _ in
      reads.bump()
      // The length read runs off the main actor.
      return Thread.isMainThread ? -1 : 600
    })
    #expect(reads.count == 0)
    #expect(model.summary == nil)
    #expect(model.refusal == nil)
    await model.refresh()
    #expect(reads.count == 1)
    #expect(model.summary?.totalSeconds == 600)
  }

  @Test("SCREEN: in Local mode or before Start sending the import is not offered, and Import opens no import space")
  @MainActor func notOfferedWithoutSending() async {
    let folder = M305Files.folder("Desktop")
    defer { M305Files.remove(folder) }
    M305Files.put(folder, "Screen Recording 2026-11-13 at 9.41.07 AM.mov")
    let ui = M305UI()
    let fakes = M305Importer()
    let recordings = ui.model(importer: fakes, suggested: folder)
    // OnboardingModel wires the rule to "signed in and sending"; here setup stops at screen 5 without consent.
    let m304 = M304Services()
    var services = m304.services
    services.recordings = recordings
    let onboarding = OnboardingModel(store: m304.store, services: services)
    for a in M304Path.toWhatLeaves { await onboarding.perform(a) }
    #expect(onboarding.flow.screen == .whatLeaves)
    #expect(!recordings.isOffered)
    #expect(!(await recordings.startImport()))
    #expect(recordings.notice == RecordingsCopy.needsSending)
    #expect(fakes.sink.spaces.isEmpty)
    #expect(ui.panel.shown == 0)
    // Local mode ("Keep it on this Mac") is the same.
    await onboarding.perform(.keepOnThisMac)
    #expect(!recordings.isOffered)
    #expect(!(await recordings.startImport()))
    // Once sending, it is offered.
    let sending = ui.model(importer: fakes, suggested: folder)
    let model = await M305.onboardingAtRecordings(sending)
    #expect(model.flow.screen == .recordings)
    #expect(sending.isOffered)
  }

  @Test("SCREEN: the model is not offered until something says the person is sending (fails closed)")
  @MainActor func failsClosed() async {
    let model = RecordingsImportModel(
      store: MemoryRecordingsFolderStore(), picker: FakeFolderPicker(), panel: FakeImportPanel(), importer: M305Importer().importer(),
      sink: nil, ledger: nil, durations: { _ in nil }, suggestedFolder: URL(fileURLWithPath: "/nowhere"), protected: [])
    #expect(!model.isOffered)
    #expect(!(await model.startImport()))
  }

  @Test("SCREEN: the Import button is free again as soon as the import has finished")
  @MainActor func importingFollowsPhase() {
    let ui = M305UI()
    let model = ui.model(importer: nil, suggested: URL(fileURLWithPath: "/nowhere"))
    #expect(!model.isImporting)
    model.apply(.started(.videos, files: 2))
    #expect(model.isImporting)
    model.apply(.finished(ImportReport(space: nil, filesRead: 0, skipped: 2, failed: 0, stillWriting: 0, moments: 0,
                                       observations: 0, firstDay: nil, lastDay: nil)))
    #expect(!model.isImporting)
    model.apply(.reading(file: 1, of: 1))
    model.apply(.failed("x"))
    #expect(!model.isImporting)
  }

  @Test("SCREEN: the folder last chosen and the import spaces survive a relaunch (UserDefaults)")
  @MainActor func defaultsStore() throws {
    let suite = "m305-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = UserDefaultsRecordingsFolderStore(defaults: defaults)
    #expect(store.folder == nil)
    #expect(store.imports.isEmpty)
    let record = ImportRecord(space: ImportSpace(id: "8d0f2f4e-0000-4000-8000-000000000001", sourceKind: .videos),
                              folderName: "Desktop", first: M305Clock.date(2026, 11, 5), last: nil, moments: 3,
                              createdAt: M305Clock.now)
    store.folder = URL(fileURLWithPath: "/tmp/Recordings", isDirectory: true)
    store.imports = [record]
    let again = UserDefaultsRecordingsFolderStore(defaults: defaults)
    #expect(again.folder?.path == "/tmp/Recordings")
    #expect(again.imports == [record])
  }

  // MARK: COPY

  @Test("COPY: no recordings string uses the terms ADR 0016 removed or a middle dot (PR #44 copyNeverMentions...OrMiddleDots)")
  func copyHasNoRemovedTermsOrMiddleDots() {
    for s in RecordingsCopy.all {
      #expect(!s.lowercased().contains("dry"), "\(s)")
      #expect(!s.lowercased().contains("preview" + " run"), "\(s)")
      #expect(!s.contains("\u{00B7}"), "\(s)")
    }
  }

  @Test("COPY: no em dash or banned word, and the refusals are plain sentences")
  func copyRules() {
    let banned = ["generous", "unlock", "seamless", "powerful", "at scale", "robust", "everything you need"]
    let folder = URL(fileURLWithPath: "/tmp/Desktop")
    let refusals = ImportRefusal.Code.allCases.map { ImportRefusal.make($0, folder: folder).message }
    for s in RecordingsCopy.all + refusals {
      #expect(!s.contains("\u{2014}"), "\(s)")
      for word in banned { #expect(!s.lowercased().contains(word), "\(s)") }
    }
    for s in refusals { #expect(s.hasSuffix("."), "\(s)") }
  }

  @Test("COPY: warnings and counts are in plain words")
  func plainWords() {
    #expect(RecordingsCopy.warning(.stillWriting(files: 1)) == "1 file is still being written. Import again when it's finished.")
    #expect(RecordingsCopy.warning(.stillWriting(files: 2)) == "2 files are still being written. Import again when they're finished.")
    #expect(RecordingsCopy.warning(.futureTime(file: "a.mov")) == "a.mov has a time in the future, so it was skipped.")
    #expect(RecordingsCopy.grouped(1284) == "1,284")
    #expect(RecordingsCopy.grouped(1_000_000) == "1,000,000")
    #expect(RecordingsCopy.grouped(12) == "12")
    #expect(RecordingsCopy.length(seconds: 6 * 3600 + 600) == "6 h 10 m")
    #expect(RecordingsCopy.length(seconds: 20) == "1 m")
  }
}
