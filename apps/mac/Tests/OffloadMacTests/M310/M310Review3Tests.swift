import Foundation
import Testing
@testable import OffloadImport
@testable import OffloadMac

// Review 3 (logs/m3-10-mac-recordings-analysis.review3.md): an idle_start closes only its own run, even when the next
// file of the same import starts within its 120 s (finding 1); the discard of unfinished imports is skipped when the
// list of imports cannot be read (finding 2); LocalAnalysis.live builds the on-device import only in .local (finding
// 3); the restored Settings window says why it waits (finding 4).
extension M310 {
  // MARK: Finding 1: runs inside one import

  /// One recording-shaped run: idle_end and a focus at the start, a text change half way, idle_start 120 s after its
  /// end (RecordingIngestor's shape).
  static func recordingRun(_ e: inout M310Events, start: Date, seconds: TimeInterval, app: (String, String)) {
    e.idleEnd(start)
    e.focus(start, app)
    e.text(start.addingTimeInterval(seconds / 2))
    e.idleStart(start.addingTimeInterval(seconds + 120))
  }

  @Test("INSIGHTS: two recordings of one import, the second starting 30 s (or 0 s) after the first ends, count both in full")
  func twoRunsOneImport() {
    for gap in [30.0, 0.0] {
      var e = M310Events(origin: .imported("imp-1"), prefix: "r")
      let a = M310Clock.date(2026, 11, 18, 10)
      Self.recordingRun(&e, start: a, seconds: 60, app: M310App.safari)
      Self.recordingRun(&e, start: a.addingTimeInterval(60 + gap), seconds: 60, app: M310App.xcode)
      let d = LocalInsights.day(e.events, day: "2026-11-18", timeZone: M310Clock.utc, exclusions: [])
      #expect(d.activeSeconds.value == 120, "gap \(gap)")
      #expect(d.perApp.map(\.appName) == ["Safari", "Xcode"], "gap \(gap)")
      #expect(d.perApp.map(\.seconds.value) == [60, 60], "gap \(gap)")
    }
  }

  @Test("INSIGHTS: two screenwatch days of one import across midnight count the full stretch on each day")
  func screenwatchAcrossMidnight() {
    var e = M310Events(origin: .imported("imp-sw"), prefix: "s")
    // Day file 1: a run from 22:00 to its last row at 23:59:58 (idle_start 120 s later, after midnight).
    e.idleEnd(M310Clock.date(2026, 11, 18, 22))
    e.focus(M310Clock.date(2026, 11, 18, 22), M310App.mail, title: "Inbox")
    e.idleStart(M310Clock.date(2026, 11, 19, 0, 1, 58))
    // Day file 2: a run from 00:00:03, Xcode held until Safari at 01:30:05, last row 02:00:00.
    e.idleEnd(M310Clock.date(2026, 11, 19, 0, 0, 3))
    e.focus(M310Clock.date(2026, 11, 19, 0, 0, 3), M310App.xcode, title: "Project")
    e.focus(M310Clock.date(2026, 11, 19, 1, 30, 5), M310App.safari, title: "Docs", host: "developer.apple.com")
    e.idleStart(M310Clock.date(2026, 11, 19, 2, 2))
    let first = LocalInsights.day(e.events, day: "2026-11-18", timeZone: M310Clock.utc, exclusions: [])
    let second = LocalInsights.day(e.events, day: "2026-11-19", timeZone: M310Clock.utc, exclusions: [])
    #expect(first.activeSeconds.value == 7198)
    #expect(second.activeSeconds.value == 7197)
    #expect(second.perApp.map(\.appName) == ["Xcode", "Safari"])
    #expect(second.perApp.map(\.seconds.value) == [5402, 1795])
  }

  @Test("INSIGHTS: in one live stream an idle_start still cuts its run back by the threshold (no change for live capture)")
  func liveStreamUnchanged() {
    var e = M310Events(origin: .live, prefix: "l")
    e.idleEnd(M310Clock.date(2026, 11, 20, 9))
    e.focus(M310Clock.date(2026, 11, 20, 9), M310App.xcode)
    e.idleStart(M310Clock.date(2026, 11, 20, 9, 2))   // a run with one input: nothing counted, as the local now summary
    e.idleEnd(M310Clock.date(2026, 11, 20, 9, 10))
    e.text(M310Clock.date(2026, 11, 20, 9, 14))
    e.idleStart(M310Clock.date(2026, 11, 20, 9, 16))
    let d = LocalInsights.day(e.events, day: "2026-11-20", timeZone: M310Clock.utc, exclusions: [])
    #expect(d.activeSeconds.value == 240)
  }

  @Test("WIRING: the real importer over two recordings 90 s apart in one folder counts both")
  @MainActor func twoRecordingsOneFolder() async throws {
    let root = M310Files.folder()
    defer { M310Files.remove(root) }
    let ui = M305UI()
    let made = try Self.onDevice(root: root, ui: ui)
    let dir = root.appendingPathComponent("Recordings", isDirectory: true)
    let firstEnd = M305Clock.now.addingTimeInterval(-3600)
    M305Files.put(dir, "a.mov", bytes: 256, modified: firstEnd)                          // 10:59:00 to 11:00:00
    M305Files.put(dir, "b.mov", bytes: 256, modified: firstEnd.addingTimeInterval(90))  // 11:00:30 to 11:01:30
    ui.store.folder = dir
    made.model.offerCheck = { true }
    let started = await made.model.startImport()
    #expect(started)
    await made.model.waitForImport()
    guard case .done(let report) = made.model.phase else {
      Issue.record("import did not finish: \(made.model.phase)")
      return
    }
    #expect(report.filesRead == 2)
    let store = InsightsStore(sources: InsightsStore.Sources(reader: made.observations, timeZone: M310Clock.utc,
                                                             now: { M310Clock.now }))
    let snapshot = await store.refreshAll()
    let day = try #require(snapshot.day("2026-11-19"))
    #expect(day.activeSeconds.value == 120)
    #expect(day.perApp.map(\.seconds.value) == [60, 60])
  }

  // MARK: Finding 2: an unreadable list of imports

  @Test("WIRING: when the list of imports cannot be read, nothing is discarded at launch")
  @MainActor func unreadableListKeepsData() async throws {
    let root = M310Files.folder()
    defer { M310Files.remove(root) }
    let paths = OnDevicePaths(offloadSupport: root.appendingPathComponent("Offload"))
    let sink = LocalImportSink(folder: paths.imports)
    let space = try await sink.openImport(sourceKind: .videos)
    try sink.write(Self.sinkObservations(space.id), to: space)
    try FileRecordingLedger(file: paths.ledger).record(RecordingLedgerEntry(
      fingerprint: "fp-kept", importID: space.id, ingestedAt: M310Clock.now, recordedAt: M310Clock.now, moments: 4))
    let ui = M305UI()
    let folders = OnDeviceRecordings.Folders(home: root.appendingPathComponent("home"), screencaptureLocation: nil, paths: paths)
    let made = try OnDeviceRecordings.make(neverWatch: NeverWatchStore(), store: ui.store, folders: folders, panel: ui.panel,
                                           picker: ui.picker, pseudonymKey: m310Key, timeZone: M310Clock.utc,
                                           durations: { _ in 60 }, appNames: nil, importsListReadable: false)
    #expect(made.discardedUnfinished.isEmpty)
    #expect(made.observations.importIDs() == [space.id])
    #expect(made.ledger.contains("fp-kept"))
  }

  @Test("WIRING: the stored list of imports is unreadable only when a value is there and does not decode")
  @MainActor func importsListReadable() throws {
    let suite = "m310-imports-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    #expect(OnDeviceRecordings.importsListReadable(defaults: defaults))
    defaults.set(Data("not a list".utf8), forKey: UserDefaultsRecordingsFolderStore.importsKey)
    #expect(!OnDeviceRecordings.importsListReadable(defaults: defaults))
    defaults.set(try JSONEncoder().encode([ImportRecord]()), forKey: UserDefaultsRecordingsFolderStore.importsKey)
    #expect(OnDeviceRecordings.importsListReadable(defaults: defaults))
  }

  // MARK: Finding 3: the launch builds the on-device import only in .local

  @Test("WIRING: LocalAnalysis.live builds the on-device import in .local and none in .cloud")
  @MainActor func liveBuildsOnDeviceOnlyLocally() throws {
    let root = M310Files.folder()
    defer { M310Files.remove(root) }
    let suite = "m310-live-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let folders = OnDeviceRecordings.Folders(home: root.appendingPathComponent("home"), screencaptureLocation: nil,
                                             paths: OnDevicePaths(offloadSupport: root.appendingPathComponent("Offload")))
    let local = LocalAnalysis.live(neverWatch: NeverWatchStore(), events: NoLocalEvents(), mode: .local, folders: folders,
                                   defaults: defaults)
    #expect(local.onDevice != nil)
    #expect(local.onDevice?.model.canImport == true)
    let cloud = BackendMode.resolve(baseURL: "https://api.example.test", tokens: M310Token())
    let remote = LocalAnalysis.live(neverWatch: NeverWatchStore(), events: NoLocalEvents(), mode: cloud, folders: folders,
                                    defaults: defaults)
    #expect(remote.onDevice == nil)
  }

  // MARK: Finding 4: the restored Settings window

  @Test("COPY: the restored Settings window says why it waits, in plain words")
  func settingsWaitingCopy() {
    #expect(NavigationCopy.settingsWaitingBody == "This window was open when Offload last quit. Nothing is read until you show it.")
    #expect(NavigationCopy.all.contains(NavigationCopy.settingsWaitingBody))
  }
}
