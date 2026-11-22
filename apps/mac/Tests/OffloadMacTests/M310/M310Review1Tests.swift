import Foundation
import Testing
@testable import OffloadImport
@testable import OffloadMac

// Review 1 (logs/m3-10-mac-recordings-analysis.review1.md): overlapping origins are counted once (finding 1), the
// launch wiring and the Never watch recount are tested end to end (finding 2), a refresh reads the imports once
// (finding 3), an old archive still ranks (finding 4), the default folders are not checked at launch (finding 5), a
// lone "." is not a path segment (finding 10) and a Mac whose on-device import could not be set up does not offer it
// (finding 10).
extension M310 {
  // MARK: Finding 1: overlapping origins

  @Test("INSIGHTS: two imports of the same time (a screenwatch day read twice) are counted once")
  func sameTimeTwoImports() {
    var a = M310Events(origin: .imported("imp-a"), prefix: "a")
    a.session(M310Clock.date(2026, 11, 18, 9), m310Pattern)
    var b = M310Events(origin: .imported("imp-b"), prefix: "b")
    b.session(M310Clock.date(2026, 11, 18, 9), m310Pattern)
    let d = LocalInsights.day(a.events + b.events, day: "2026-11-18", timeZone: M310Clock.utc, exclusions: [])
    #expect(d.activeSeconds.value == 1800)
    #expect(d.perApp.map(\.seconds.value) == [600, 600, 600])
    #expect(d.switches.value == 2)
    #expect(d.spans.count == 3)
    // A tie between imports is broken by import id, so the same import wins every time.
    #expect(d.spans.allSatisfy { $0.firstEventID.hasPrefix("a-") })
  }

  @Test("INSIGHTS: where a detailed import (titles, hosts) overlaps a recording it wins; the rest of the recording keeps its time")
  func detailedImportWinsOverlap() {
    var watch = M310Events(origin: .imported("imp-z"), prefix: "z")
    watch.session(M310Clock.date(2026, 11, 18, 9), m310Pattern)                // 9:00 to 9:30, titles and a host
    var video = M310Events(origin: .imported("imp-a"), prefix: "v")
    video.idleEnd(M310Clock.date(2026, 11, 18, 9, 20))
    video.focus(M310Clock.date(2026, 11, 18, 9, 20), M310App.mail)          // 9:20 to 9:50, app only
    video.idleStart(M310Clock.date(2026, 11, 18, 9, 52))
    let d = LocalInsights.day(watch.events + video.events, day: "2026-11-18", timeZone: M310Clock.utc, exclusions: [])
    #expect(d.activeSeconds.value == 3000)
    #expect(d.perApp.map(\.appName) == ["Mail", "Xcode", "Safari", "Slack"])
    #expect(d.perApp.map(\.seconds.value) == [1200, 600, 600, 600])
    #expect(d.spans.first { $0.appName == "Mail" }?.start == M310Clock.date(2026, 11, 18, 9, 30))
  }

  @Test("INSIGHTS: live capture wins over an import of the same time, and the day is the union of both")
  func liveWinsOverImport() {
    var live = M310Events(origin: .live, prefix: "l")
    live.focus(M310Clock.date(2026, 11, 20, 9), M310App.xcode)
    live.text(M310Clock.date(2026, 11, 20, 9, 4))
    live.text(M310Clock.date(2026, 11, 20, 9, 8))
    live.text(M310Clock.date(2026, 11, 20, 9, 10))
    live.idleStart(M310Clock.date(2026, 11, 20, 9, 12))
    var imported = M310Events(origin: .imported("imp-1"), prefix: "i")
    imported.session(M310Clock.date(2026, 11, 20, 9), [(M310App.slack, "#ops", nil, 20)])
    let d = LocalInsights.day(live.events + imported.events, day: "2026-11-20", timeZone: M310Clock.utc, exclusions: [])
    #expect(d.activeSeconds.value == 1200)
    #expect(d.perApp.map(\.appName) == ["Xcode", "Slack"])
    #expect(d.perApp.map(\.seconds.value) == [600, 600])
    #expect(d.activeSeconds.value <= 86_400)
  }

  // MARK: Finding 2: launch wiring and the Never watch recount

  /// An app over m3-04's fakes with an injected insights store (one imported day with Slack), launched as
  /// AppModel.live() does it.
  @MainActor static func launched() -> (app: AppModel, reader: M310Reader) {
    var e = M310Events(prefix: "w")
    e.session(M310Clock.date(2026, 11, 18, 9), m310Pattern)
    let reader = M310Reader(e.events)
    let box = ExclusionRulesBox()
    let insights = InsightsModel(store: InsightsStore(sources: InsightsStore.Sources(
      reader: reader, exclusions: { box.rules }, timeZone: M310Clock.utc, now: { M310Clock.now })))
    let kit = M310AppKit(state: M310AppKit.doneLocal)
    let recordings = M305UI().model(importer: nil, suggested: URL(fileURLWithPath: "/tmp"))
    let app = kit.app(recordings: recordings, insights: insights)
    let neverWatch = kit.fakes.neverWatch
    app.startLocalAnalysis(rules: box, ruleProvider: { NeverWatchImportExclusions(source: neverWatch).currentRules() })
    return (app, reader)
  }

  /// Take the snapshot (a Sendable value read on the main actor by the caller), not the app: AppModel and its
  /// insights model are main-actor isolated, and these helpers run inside #expect's nonisolated closure.
  static func slackCounted(_ snapshot: InsightsSnapshot) -> Bool {
    snapshot.day("2026-11-18")?.perApp.contains { $0.appName == "Slack" } == true
  }

  static func neverWatchCounted(_ snapshot: InsightsSnapshot) -> Bool {
    snapshot.day("2026-11-18")?.perApp.contains { $0.appName == "Never watch app" } == true
  }

  @Test("WIRING: at launch the local analysis counts the imported days once, reading the imports once")
  @MainActor func launchCountsOnce() async {
    let (app, reader) = Self.launched()
    await app.insights.idle()
    let recomputed = await app.insights.store.recomputed
    #expect(recomputed == ["2026-11-18"])
    #expect(reader.reads == 1)
    #expect(Self.slackCounted(app.insights.snapshot))
    #expect(app.recordings?.isOffered == false)  // importer nil: nothing to offer on this Mac (finding 10)
  }

  @Test("EXCLUDE: Don't watch from the menu bar recounts without a new import; the app shows as Never watch app")
  @MainActor func menuBarDontWatchRecounts() async {
    let (app, _) = Self.launched()
    await app.insights.idle()
    await app.dontWatch(Exclusion(kind: .bundleID, value: M310App.slack.0))
    await app.insights.idle()
    #expect(!Self.slackCounted(app.insights.snapshot))
    #expect(Self.neverWatchCounted(app.insights.snapshot))
    let recomputed = await app.insights.store.recomputed
    #expect(recomputed == ["2026-11-18", "2026-11-18"])
  }

  @Test("EXCLUDE: a Never watch entry added in the sheet (through onboarding) recounts too")
  @MainActor func sheetEntryRecounts() async {
    let (app, _) = Self.launched()
    await app.insights.idle()
    await app.onboarding.perform(.neverWatch(add: [Exclusion(kind: .bundleID, value: M310App.slack.0)]))
    await app.insights.idle()
    #expect(Self.neverWatchCounted(app.insights.snapshot))
    // Closing the sheet asks again; nothing changed since, so nothing is recounted.
    app.insights.exclusionsChanged()
    await app.insights.idle()
    let recomputed = await app.insights.store.recomputed
    #expect(recomputed == ["2026-11-18", "2026-11-18"])
  }

  @Test("WIRING: in .local, a Mac whose on-device import could not be set up does not offer Import and says why")
  @MainActor func fallbackNotOffered() {
    #expect(!RecordingsOffer.isOffered(mode: .local, sending: false, canImportLocally: false))
    #expect(RecordingsOffer.isOffered(mode: .local, sending: false, canImportLocally: true))
    let kit = M310AppKit(state: M310AppKit.doneLocal)
    let app = kit.app(recordings: M305UI().model(importer: nil, suggested: URL(fileURLWithPath: "/tmp")))
    app.wireRecordingsOffer()
    #expect(app.recordings?.isOffered == false)
    #expect(NavigationCopy.localImportUnavailable.hasPrefix("Offload couldn't set up"))
    #expect(NavigationCopy.all.contains(NavigationCopy.localImportUnavailable))
  }

  // MARK: Finding 3: one read per refresh

  @Test("INCREMENTAL: a refresh reads the imports once, and recomputing days reads them once more")
  func refreshReadsOnce() async {
    var e = M310Events(prefix: "q")
    for d in [16, 17, 18] { e.session(M310Clock.date(2026, 11, d, 9), m310Pattern) }
    let reader = M310Reader(e.events)
    let store = InsightsStore(sources: InsightsStore.Sources(reader: reader, timeZone: M310Clock.utc, now: { M310Clock.now }))
    let all = await store.refreshAll()
    #expect(all.observedDays == ["2026-11-16", "2026-11-17", "2026-11-18"])
    #expect(reader.reads == 1)
    await store.recompute(days: ["2026-11-16", "2026-11-17"])
    #expect(reader.reads == 2)
  }

  // MARK: Finding 4: an old archive

  @Test("RANK: an archive older than 8 weeks still ranks; the 8 weeks count back from the last observed day")
  func oldArchiveRanks() throws {
    let days = [m310Day(2026, 8, 3, sessions: [(9, m310Pattern)]), m310Day(2026, 8, 6, sessions: [(9, m310Pattern)]),
                m310Day(2026, 8, 12, sessions: [(9, m310Pattern)])]
    let r = try #require(LocalInsights.repeats(days: days, now: M310Clock.now, timeZone: M310Clock.utc).first)
    #expect(r.weeksObserved == 2 && r.weeksPresent == 2)
    #expect(r.persistence == 1)
    #expect(r.score > 0)
  }

  // MARK: Finding 5: nothing checked at launch

  @Test("FOLDERS: at launch only ~/screenwatch is checked; the default folders are found when the Recordings screen asks")
  @MainActor func foldersFoundOnRequest() throws {
    let root = M310Files.folder()
    defer { M310Files.remove(root) }
    let home = root.appendingPathComponent("home", isDirectory: true)
    for name in ["Desktop", "Movies"] {
      try FileManager.default.createDirectory(at: home.appendingPathComponent(name), withIntermediateDirectories: true)
    }
    let asked = M310Asked()
    let folders = OnDeviceRecordings.Folders(home: home, screencaptureLocation: "~/Documents/Captures",
                                             paths: OnDevicePaths(offloadSupport: root.appendingPathComponent("Offload")),
                                             exists: { asked.add($0); return FileManager.default.fileExists(atPath: $0) })
    let ui = M305UI()
    let made = try OnDeviceRecordings.make(neverWatch: NeverWatchStore(), store: ui.store, folders: folders, panel: ui.panel,
                                           picker: ui.picker, pseudonymKey: m310Key, timeZone: M310Clock.utc,
                                           durations: { _ in 60 }, appNames: nil)
    let screenwatch = home.appendingPathComponent("screenwatch")
    let allowed: Set<String> = [screenwatch.path, screenwatch.appendingPathComponent("days").path]
    #expect(Set(asked.all.map { URL(fileURLWithPath: $0).path }).isSubset(of: allowed))
    #expect(made.folderCandidates.candidates.isEmpty)
    // No folder is checked for the suggestion either: it is where macOS saves screen recordings.
    // A folder URL (trailing slash); Documents/Captures does not exist, so the expected URL says it is a directory.
    #expect(made.model.folder?.standardizedFileURL
            == home.appendingPathComponent("Documents/Captures", isDirectory: true).standardizedFileURL)
    made.folderCandidates.refresh()
    #expect(made.folderCandidates.candidates.map(\.kind) == [.desktop, .movies])
  }
}
