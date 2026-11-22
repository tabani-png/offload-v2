import Foundation
import Testing
@testable import OffloadImport
@testable import OffloadMac

// Review 2 (logs/m3-10-mac-recordings-analysis.review2.md): idle_start is moved back by the idle threshold, as m3-05's
// readers write it and m3-04's local now summary reads it (finding 1); an import a quit left unfinished is discarded
// at launch (finding 2); a restored Settings window reads no folder until asked (finding 3); in .cloud nothing is
// imported into the on-device sink (finding 4); the files' protection class is pinned (finding 5).
extension M310 {
  // MARK: Finding 1: idle_start is backdated

  @Test("INSIGHTS: idle_start is moved back by the idle threshold; a span opened after that point is dropped and one running past it is cut")
  func idleStartBackdated() {
    var e = M310Events(prefix: "b")
    e.idleEnd(M310Clock.date(2026, 11, 18, 9))
    e.focus(M310Clock.date(2026, 11, 18, 9), M310App.xcode)
    e.focus(M310Clock.date(2026, 11, 18, 9, 31), M310App.slack)   // after the last activity (9:30)
    e.idleStart(M310Clock.date(2026, 11, 18, 9, 32))              // last activity 9:30 + 120 s
    let d = LocalInsights.day(e.events, day: "2026-11-18", timeZone: M310Clock.utc, exclusions: [])
    #expect(d.activeSeconds.value == 1800)
    #expect(d.perApp.map(\.appName) == ["Xcode"])
    #expect(d.spans.last?.end == M310Clock.date(2026, 11, 18, 9, 30))
  }

  @Test("INSIGHTS: local insights and m3-04's local now summary agree on active time for the same live events")
  func agreesWithLocalNowSummary() {
    let t = M310Clock.date(2026, 11, 20, 17)
    let events = [
      LocalEvent(id: "L1", ts: m310Ms(t), kind: "focus", app: "com.apple.dt.Xcode", appName: "Xcode"),
      LocalEvent(id: "L2", ts: m310Ms(t.addingTimeInterval(240)), kind: "input", app: nil, appName: nil),
      LocalEvent(id: "L3", ts: m310Ms(t.addingTimeInterval(480)), kind: "input", app: nil, appName: nil),
      LocalEvent(id: "L4", ts: m310Ms(t.addingTimeInterval(600)), kind: "idle_start", app: nil, appName: nil),
    ]
    let now = LocalNowSummary.compute(events: events, now: m310Ms(t.addingTimeInterval(600)), minutes: 10)
    let insights = LocalInsights.day(events.compactMap { InsightEvent(local: $0) }, day: "2026-11-20",
                                     timeZone: M310Clock.utc, exclusions: [])
    #expect(now.activeMs == 480_000)
    #expect(insights.activeSeconds.value == Double(now.activeMs) / 1000)
  }

  @Test("WIRING: a real import of a 60 s recording, through the local sink and store, counts 60 s of activity")
  @MainActor func importToFigures() async throws {
    let root = M310Files.folder()
    defer { M310Files.remove(root) }
    let ui = M305UI()
    // The folder chosen last time is read when the model is made (m3-05), so it is kept before OnDeviceRecordings.make.
    ui.store.folder = Self.recordingsFolder(root)
    let made = try Self.onDevice(root: root, ui: ui)
    made.model.offerCheck = { true }
    let started = await made.model.startImport()
    #expect(started)
    await made.model.waitForImport()
    let store = InsightsStore(sources: InsightsStore.Sources(reader: made.observations, timeZone: M310Clock.utc,
                                                             now: { M310Clock.now }))
    let snapshot = await store.refreshAll()
    let day = try #require(snapshot.day("2026-11-19"))
    #expect(day.activeSeconds.value == 60)
    #expect(day.perApp.map(\.appName) == ["Safari", "Slack"])
    #expect(day.perApp.map(\.seconds.value) == [30, 30])
  }

  // MARK: Finding 2: an unfinished import

  @Test("WIRING: an import a quit left unfinished is discarded at launch with its ledger entries; finished imports stay")
  @MainActor func unfinishedImportDiscarded() async throws {
    let root = M310Files.folder()
    defer { M310Files.remove(root) }
    let paths = OnDevicePaths(offloadSupport: root.appendingPathComponent("Offload"))
    let sink = LocalImportSink(folder: paths.imports)
    let unfinished = try await sink.openImport(sourceKind: .videos)
    let finished = try await sink.openImport(sourceKind: .videos)
    try sink.write(Self.sinkObservations(unfinished.id), to: unfinished)
    try sink.write(Self.sinkObservations(finished.id), to: finished)
    let ledger = FileRecordingLedger(file: paths.ledger)
    try ledger.record(RecordingLedgerEntry(fingerprint: "fp-unfinished", importID: unfinished.id, ingestedAt: M310Clock.now,
                                           recordedAt: M310Clock.now, moments: 12))
    try ledger.record(RecordingLedgerEntry(fingerprint: "fp-finished", importID: finished.id, ingestedAt: M310Clock.now,
                                           recordedAt: M310Clock.now, moments: 12))
    let ui = M305UI()
    ui.store.imports = [ImportRecord(space: finished, folderName: "Recordings", first: nil, last: nil, moments: 12,
                                     createdAt: M310Clock.now)]
    let made = try Self.onDevice(root: root, ui: ui)
    #expect(made.discardedUnfinished == [unfinished.id])
    #expect(made.observations.importIDs() == [finished.id])
    #expect(!made.ledger.contains("fp-unfinished"))
    #expect(made.ledger.contains("fp-finished"))
    #expect(made.model.imports.map(\.space.id) == [finished.id])
  }

  // MARK: Finding 3: a restored Settings window

  @Test("NAV: a Settings window macOS restores at launch reads no folder until the person asks for it")
  @MainActor func settingsWindowWaitsForRequest() {
    let nav = NavigationModel()
    #expect(!nav.settingsRequested)
    #expect(SettingsWindowContent.forRequested(nav.settingsRequested) == .waiting)
    nav.requestSettings()
    #expect(nav.settingsRequested)
    #expect(SettingsWindowContent.forRequested(nav.settingsRequested) == .recordings)
    #expect(NavigationCopy.all.contains(NavigationCopy.showRecordingsSettings))
  }

  // MARK: Finding 4: .cloud

  @Test("WIRING: only .local imports into the on-device sink; .cloud keeps m3-05's import")
  func cloudKeepsM305Import() {
    #expect(LocalAnalysis.importsOnThisMac(mode: .local))
    let cloud = BackendMode.resolve(baseURL: "https://api.example.test", tokens: M310Token())
    #expect(!LocalAnalysis.importsOnThisMac(mode: cloud))
  }

  // MARK: Finding 5: file protection

  @Test("SINK: files are written with protection until first unlock, not complete protection")
  func protectionClass() {
    #expect(OnDeviceFiles.writeOptions.intersection(.fileProtectionMask) == .completeFileProtectionUntilFirstUserAuthentication)
    #expect(OnDeviceFiles.writeOptions.contains(.withoutOverwriting))
  }
}
