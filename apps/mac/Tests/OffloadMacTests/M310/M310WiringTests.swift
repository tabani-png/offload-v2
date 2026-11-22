import Foundation
import Testing
@testable import OffloadImport
@testable import OffloadMac

// The wiring: OnDeviceRecordings into AppModel, the offer rule, the insights coordinator (incremental recompute), the
// done line, the navigation shell, the Sample data rule and the new copy.
extension M310 {
  /// A scripted 60 s recording of Safari whose page shows an email and a card number.
  static let script = M305Script(id: "rec", duration: 60, scenes: [
    M305Scene(at: 0, lines: m305Screen(app: "Safari", body: "Mail amara@example.com about card 4111 1111 1111 1111"), hash: 0),
    M305Scene(at: 30, lines: m305Screen(app: "Slack", body: "Thanks, see https://acme.example.com/inv/2041?x=1"), hash: 0),
  ])

  /// OnDeviceRecordings over a temporary support folder, a scripted recognizer and scripted frames.
  @MainActor static func onDevice(root: URL, ui: M305UI, neverWatch: NeverWatchStore = NeverWatchStore()) throws -> OnDeviceRecordings {
    let script = Self.script
    let readers = RecordingImporter.Readers(
      openVideo: { _ in FakeRecording(script) },
      openImage: { url in ImportFrame(width: 1280, height: 800, tag: url.lastPathComponent) }
    )
    let folders = OnDeviceRecordings.Folders(home: root.appendingPathComponent("home"), screencaptureLocation: nil,
                                             paths: OnDevicePaths(offloadSupport: root.appendingPathComponent("Offload")))
    return try OnDeviceRecordings.make(neverWatch: neverWatch, store: ui.store, folders: folders, panel: ui.panel,
                                       picker: ui.picker, recognizer: ScriptedRecognizer([script]), pseudonymKey: m310Key,
                                       readers: readers, clock: FakeClock(), timeZone: M310Clock.utc,
                                       durations: { _ in 60 }, appNames: nil)
  }

  /// A recordings folder with one recording, written an hour before the fake clock.
  static func recordingsFolder(_ root: URL) -> URL {
    let dir = root.appendingPathComponent("Recordings", isDirectory: true)
    M305Files.put(dir, "rec.mov", bytes: 256, modified: M305Clock.now.addingTimeInterval(-3600))
    return dir
  }

  // MARK: WIRING

  @Test("WIRING: OnDeviceRecordings.make gives a model that can import, the local sink and a file ledger under the folder")
  @MainActor func makeWiresTheImporter() throws {
    let root = M310Files.folder()
    defer { M310Files.remove(root) }
    let made = try Self.onDevice(root: root, ui: M305UI())
    let paths = OnDevicePaths(offloadSupport: root.appendingPathComponent("Offload"))
    #expect(made.model.canImport)
    #expect(made.sink.folder == paths.imports)
    #expect(made.ledger.file == paths.ledger)
    #expect(made.observations.folder == paths.imports)
    #expect(paths.root.path.hasPrefix(root.path))
    #expect(M310Files.mode(paths.root) == 0o700)
  }

  @Test("WIRING: an import of a folder writes masked observations that the store reads back, with no text, email or file name")
  @MainActor func importWritesLocally() async throws {
    let root = M310Files.folder()
    defer { M310Files.remove(root) }
    let ui = M305UI()
    let made = try Self.onDevice(root: root, ui: ui)
    ui.store.folder = Self.recordingsFolder(root)
    let model = made.model
    model.offerCheck = { true }
    let started = await model.startImport()
    #expect(started)
    await model.waitForImport()
    guard case .done(let report) = model.phase else {
      Issue.record("import did not finish: \(model.phase)")
      return
    }
    #expect(report.filesRead == 1)
    let ids = made.observations.importIDs()
    #expect(ids == [report.space?.id ?? ""])
    let stored = made.observations.stored(importID: ids[0])
    #expect(stored.contains { $0.kind == "focus" && $0.appName == "Safari" })
    #expect(stored.contains { $0.kind == "text_snapshot" && $0.textHash?.count == 64 })
    let raw = try String(contentsOf: made.sink.file(for: ids[0]), encoding: .utf8)
    for leak in ["amara", "@", "CARD NO.", "<email", "rec.mov", "Recordings", "acme.example.com/inv", root.path] {
      #expect(!raw.contains(leak), "\(leak) was stored")
    }
    let events = made.observations.events(in: DateInterval(start: M310Clock.date(2026, 11, 19), end: M310Clock.date(2026, 11, 20)))
    #expect(events.contains { $0.kind == .focus && $0.appName == "Slack" })
  }

  @Test("WIRING: offered in .local without sign-in, not in .cloud before sending, offered in .cloud while sending")
  @MainActor func offerRule() throws {
    let root = M310Files.folder()
    defer { M310Files.remove(root) }
    let cloud = BackendMode.resolve(baseURL: "https://api.example.test", tokens: M310Token())
    #expect(!cloud.isLocal)
    #expect(RecordingsOffer.isOffered(mode: .local, sending: false))
    #expect(!RecordingsOffer.isOffered(mode: cloud, sending: false))
    #expect(RecordingsOffer.isOffered(mode: cloud, sending: true))

    let local = M310AppKit(state: M310AppKit.doneLocal)
    let localApp = local.app(recordings: try Self.onDevice(root: root, ui: M305UI()).model)
    #expect(localApp.recordings?.isOffered == false)  // m3-05's rule until AppModel wires m3-10's
    localApp.wireRecordingsOffer()
    #expect(localApp.recordings?.isOffered == true)

    let cloudKit = M310AppKit(state: M310AppKit.doneLocal)
    let cloudApp = cloudKit.app(recordings: try Self.onDevice(root: root, ui: M305UI()).model, backends: Backends.make(mode: cloud, transport: RecordingTransport()))
    cloudApp.wireRecordingsOffer()
    #expect(cloudApp.recordings?.isOffered == false)

    var sending = M310AppKit.doneLocal
    sending.signedIn = true
    sending.uploadConsent = true
    let sendingKit = M310AppKit(state: sending)
    let sendingApp = sendingKit.app(recordings: try Self.onDevice(root: root, ui: M305UI()).model, backends: Backends.make(mode: cloud, transport: RecordingTransport()))
    sendingApp.wireRecordingsOffer()
    #expect(sendingApp.recordings?.isOffered == true)
  }

  @Test("WIRING: Import in .local touches neither the consent service nor the uploader")
  @MainActor func localImportSendsNothing() async throws {
    let root = M310Files.folder()
    defer { M310Files.remove(root) }
    let ui = M305UI()
    let made = try Self.onDevice(root: root, ui: ui)
    ui.store.folder = Self.recordingsFolder(root)
    let kit = M310AppKit(state: M310AppKit.doneLocal)
    let app = kit.app(recordings: made.model, onDevice: made)
    app.wireRecordingsOffer()
    let started = await made.model.startImport()
    #expect(started)
    await made.model.waitForImport()
    #expect(kit.fakes.consent.recorded.isEmpty)
    #expect(kit.fakes.uploader.starts == 0)
    #expect(app.backends.brain == nil && app.backends.builds == nil)
  }

  @Test("WIRING: Use this folder makes a default folder the chosen one, kept for next time")
  @MainActor func useCandidateFolder() async throws {
    let root = M310Files.folder()
    defer { M310Files.remove(root) }
    let ui = M305UI()
    let home = root.appendingPathComponent("home", isDirectory: true)
    try FileManager.default.createDirectory(at: home.appendingPathComponent("Movies"), withIntermediateDirectories: true)
    let made = try Self.onDevice(root: root, ui: ui)
    made.folderCandidates.refresh()
    let movies = try #require(made.folderCandidates.candidates.first { $0.kind == .movies })
    made.model.offerCheck = { true }
    await made.use(movies)
    #expect(made.model.folder == movies.url)
    #expect(ui.store.folder == movies.url)
    #expect(ui.picker.asked.isEmpty)
  }

  // MARK: INCREMENTAL

  static func report(first: Date, last: Date, files: Int = 1) -> ImportReport {
    ImportReport(space: ImportSpace(id: "imp-1", sourceKind: .videos), filesRead: files, skipped: 0, failed: 0, stillWriting: 0,
                 moments: 12, observations: 30, firstDay: first, lastDay: last)
  }

  @MainActor static func insights(_ reader: M310Reader, live: (any LocalEventSource)? = nil) -> InsightsModel {
    InsightsModel(store: InsightsStore(sources: InsightsStore.Sources(reader: reader, live: live, timeZone: M310Clock.utc,
                                                                      now: { M310Clock.now })))
  }

  @Test("INCREMENTAL: a finished import recomputes only the days from its first to its last day")
  @MainActor func finishedImportRecomputesItsDays() async {
    let insights = Self.insights(M310Reader())
    let model = M305UI().model(importer: nil, suggested: URL(fileURLWithPath: "/tmp"))
    let coordinator = insights.observe(model)
    model.apply(.finished(Self.report(first: M310Clock.date(2026, 11, 16, 10), last: M310Clock.date(2026, 11, 18, 9))))
    await coordinator.idle()
    let recomputed = await insights.store.recomputed
    #expect(recomputed == ["2026-11-16", "2026-11-17", "2026-11-18"])
  }

  @Test("INCREMENTAL: removing an import recomputes its days and its repeats disappear")
  @MainActor func removingAnImport() async {
    var e = M310Events(prefix: "r")
    for d in [16, 17, 18] { e.session(M310Clock.date(2026, 11, d, 9), m310Pattern) }
    let reader = M310Reader(e.events)
    let insights = Self.insights(reader)
    await insights.refreshAll()
    #expect(insights.snapshot.thingsYouRepeat.count == 1)
    let ui = M305UI()
    let record = ImportRecord(space: ImportSpace(id: "imp-1", sourceKind: .videos), folderName: "Recordings",
                              first: M310Clock.date(2026, 11, 16, 9), last: M310Clock.date(2026, 11, 18, 9, 30), moments: 12,
                              createdAt: M310Clock.now)
    ui.store.imports = [record]
    let model = ui.model(importer: nil, suggested: URL(fileURLWithPath: "/tmp"))
    let coordinator = insights.observe(model)
    reader.set([])
    await model.remove(record)
    await coordinator.idle()
    #expect(insights.snapshot.thingsYouRepeat.isEmpty)
    #expect(insights.snapshot.days.isEmpty)
    let recomputed = await insights.store.recomputed
    #expect(Array(recomputed.suffix(3)) == ["2026-11-16", "2026-11-17", "2026-11-18"])
  }

  @Test("INCREMENTAL: a second import of other days leaves the cached days untouched")
  @MainActor func secondImportOtherDays() async {
    var e = M310Events(prefix: "s")
    for d in [16, 17, 18, 19] { e.session(M310Clock.date(2026, 11, d, 9), m310Pattern) }
    let insights = Self.insights(M310Reader(e.events))
    let model = M305UI().model(importer: nil, suggested: URL(fileURLWithPath: "/tmp"))
    let coordinator = insights.observe(model)
    model.apply(.finished(Self.report(first: M310Clock.date(2026, 11, 16, 9), last: M310Clock.date(2026, 11, 17, 9))))
    await coordinator.idle()
    model.apply(.finished(Self.report(first: M310Clock.date(2026, 11, 18, 9), last: M310Clock.date(2026, 11, 19, 9))))
    await coordinator.idle()
    let recomputed = await insights.store.recomputed
    #expect(recomputed == ["2026-11-16", "2026-11-17", "2026-11-18", "2026-11-19"])
    #expect(insights.snapshot.observedDays == ["2026-11-16", "2026-11-17", "2026-11-18", "2026-11-19"])
  }

  @Test("INCREMENTAL: live events from a LocalEventSource are counted for today with the imported days")
  @MainActor func liveEventsCountedToday() async {
    var e = M310Events(prefix: "i")
    e.session(M310Clock.date(2026, 11, 18, 9), m310Pattern)
    let t = M310Clock.date(2026, 11, 20, 17)
    let live = M310LiveEvents(events: [
      LocalEvent(id: "L1", ts: m310Ms(t), kind: "focus", app: "com.apple.dt.Xcode", appName: "Xcode"),
      LocalEvent(id: "L2", ts: m310Ms(t.addingTimeInterval(240)), kind: "input", app: nil, appName: nil),
      LocalEvent(id: "L3", ts: m310Ms(t.addingTimeInterval(480)), kind: "input", app: nil, appName: nil),
      LocalEvent(id: "L4", ts: m310Ms(t.addingTimeInterval(600)), kind: "idle_start", app: nil, appName: nil),
    ])
    let insights = Self.insights(M310Reader(e.events), live: live)
    await insights.refreshAll()
    #expect(insights.snapshot.observedDays == ["2026-11-18", "2026-11-20"])
    // idle_start at 17:10 is the observer's "last input 17:08 + 120 s": 17:00 to 17:08 (review 2, as LocalNowSummary).
    #expect(insights.snapshot.day("2026-11-20")?.activeSeconds.value == 480)
    #expect(insights.snapshot.day("2026-11-18")?.activeSeconds.value == 1800)
  }

  @Test("INCREMENTAL: nothing is recomputed while no import has finished")
  @MainActor func nothingWhileNoImportFinished() async {
    let insights = Self.insights(M310Reader())
    let model = M305UI().model(importer: nil, suggested: URL(fileURLWithPath: "/tmp"))
    let coordinator = insights.observe(model)
    model.apply(.started(.videos, files: 3))
    model.apply(.reading(file: 1, of: 3))
    model.apply(.refused(ImportRefusal.make(.noRecordings, folder: URL(fileURLWithPath: "/tmp/Empty"))))
    model.apply(.finished(ImportReport(space: nil, filesRead: 0, skipped: 2, failed: 0, stillWriting: 0, moments: 0,
                                       observations: 0, firstDay: nil, lastDay: nil)))
    await coordinator.idle()
    let recomputed = await insights.store.recomputed
    #expect(recomputed.isEmpty)
    #expect(!insights.isAnalysing)
  }

  // MARK: PROGRESS

  static let doneReport = ImportReport(space: ImportSpace(id: "imp-1", sourceKind: .videos), filesRead: 11, skipped: 0,
                                       failed: 1, stillWriting: 0, moments: 1284, observations: 3000,
                                       firstDay: nil, lastDay: nil)

  @Test("PROGRESS: the done items are done, 1,284 moments read and 9 things you repeat")
  func doneLineWithRepeats() {
    #expect(AnalysisCopy.doneItems(Self.doneReport, repeats: 9) == ["done", "1,284 moments read", "9 things you repeat"])
  }

  @Test("PROGRESS: one repeat reads 1 thing you repeat")
  func doneLineOneRepeat() {
    #expect(AnalysisCopy.doneItems(Self.doneReport, repeats: 1) == ["done", "1,284 moments read", "1 thing you repeat"])
  }

  @Test("PROGRESS: with no repeat the count is left out; while counting it says so")
  func doneLineNoRepeats() {
    #expect(AnalysisCopy.doneItems(Self.doneReport, repeats: 0) == ["done", "1,284 moments read"])
    #expect(AnalysisCopy.doneItems(Self.doneReport, repeats: nil) == ["done", "1,284 moments read", "counting on this Mac"])
  }

  @Test("PROGRESS: No new recordings. is unchanged")
  func doneLineNothingNew() {
    let none = ImportReport(space: nil, filesRead: 0, skipped: 4, failed: 0, stillWriting: 0, moments: 0, observations: 0,
                            firstDay: nil, lastDay: nil)
    #expect(AnalysisCopy.doneItems(none, repeats: 9) == ["No new recordings."])
    #expect(AnalysisCopy.doneItems(none, repeats: nil) == ["No new recordings."])
  }

  @Test("PROGRESS: the Recordings screen and the panel show the same line from the model and the snapshot")
  @MainActor func screenShowsTheSameLine() {
    let model = M305UI().model(importer: nil, suggested: URL(fileURLWithPath: "/tmp"))
    let insights = InsightsModel.empty(timeZone: M310Clock.utc)
    model.apply(.reading(file: 3, of: 12))
    #expect(AnalysisProgress.items(model, insights: insights) == ["reading file 3 of 12"])
    model.apply(.finished(Self.doneReport))
    let nine = (0..<9).map { m310Ranked(key: "k_00000000000\($0)", score: Double(9 - $0)) }
    insights.publish(InsightsSnapshot(days: [], repeats: nine, observedDays: [], lastUpdated: M310Clock.now))
    #expect(AnalysisProgress.items(model, insights: insights) == ["done", "1,284 moments read", "9 things you repeat"])
  }

  // MARK: NAV

  @Test("NAV: the sidebar order and titles")
  func sidebar() {
    #expect(Screen.allCases.map(\.title) == ["Today", "Weekly review", "Builds", "Recordings", "Settings"])
    #expect(Screen.allCases == [.today, .weeklyReview, .builds, .recordings, .settings])
  }

  @Test("NAV: the shell shows only when the route is Today; onboarding routes still show MainWindowView")
  func shellOnlyOnToday() {
    #expect(AppWindowContent.forRoute(.today) == .shell)
    #expect(AppWindowContent.forRoute(.onboarding(.install)) == .setup)
    #expect(AppWindowContent.forRoute(.onboarding(.recordings)) == .setup)
    #expect(AppWindowContent.forRoute(.moveToApplications) == .setup)
    #expect(AppWindowContent.forRoute(.startFresh) == .setup)
  }

  @Test("NAV: startBuild selects Builds with the request, handed over once")
  @MainActor func startBuildHandsOff() {
    let nav = NavigationModel()
    #expect(nav.selection == .today)
    let request = BuildRequest.localRepeat(key: "k_0123456789ab", name: "Xcode, then Slack", minutesPerWeek: 145)
    nav.startBuild(request)
    #expect(nav.selection == .builds)
    #expect(nav.pendingBuild == request)
    #expect(nav.takePendingBuild() == request)
    #expect(nav.takePendingBuild() == nil)
    nav.startBuild(.opportunity(id: "opp-1", optionID: "opt-2"))
    #expect(nav.pendingBuild == .opportunity(id: "opp-1", optionID: "opt-2"))
  }

  @Test("NAV: each screen exists with its (app:) initialiser")
  @MainActor func screensExist() {
    let app = M310AppKit(state: M310AppKit.doneLocal).app()
    _ = TodayLiveScreen(app: app)
    _ = WeeklyReviewScreen(app: app)
    _ = WeeklyReviewSettings(app: app)
    _ = BuildProgressScreen(app: app)
    _ = RecordingsScreen(app: app)
    _ = SettingsScreen(app: app)
    _ = ShellView(app: app)
    _ = AppWindowView(app: app)
    #expect(app.route == .today)
  }

  @Test("NAV: the Never watch sheet opens from the shell")
  @MainActor func neverWatchFromShell() {
    let app = M310AppKit(state: M310AppKit.doneLocal).app()
    #expect(AppWindowContent.forRoute(app.route) == .shell)
    app.showNeverWatch()
    #expect(app.showingNeverWatch)
  }

  @Test("NAV: AppModel's new properties default so m3-04's and m3-05's callers compile unchanged")
  @MainActor func appModelDefaults() {
    let app = M304Services().app()
    #expect(app.navigation.selection == .today)
    #expect(app.backends.mode.isLocal)
    #expect(app.backends.provenance == .onDevice)
    #expect(app.insights.snapshot.isEmpty)
    #expect(app.onDeviceRecordings == nil)
  }

  // MARK: SAMPLE

  @Test("SAMPLE: sample provenance shows Sample data: cloud not connected, as a warning")
  func sampleLabel() {
    #expect(DataProvenance.sample.label == "Sample data: cloud not connected")
    #expect(DataProvenance.sample.isWarning)
    #expect(NavigationCopy.sampleData == "Sample data: cloud not connected")
  }

  @Test("SAMPLE: on-device provenance shows counted on this Mac")
  func onDeviceCaption() {
    #expect(DataProvenance.onDevice.label == "counted on this Mac")
    #expect(!DataProvenance.onDevice.isWarning)
  }

  @Test("SAMPLE: cloud provenance shows neither")
  func cloudShowsNothing() {
    #expect(DataProvenance.cloud.label == nil)
  }

  @Test("SAMPLE: sample provenance cannot be produced in .cloud mode")
  func noSampleInCloud() {
    #expect(DataProvenance.sample(in: .local) == .sample)
    let cloud = BackendMode.resolve(baseURL: "https://api.example.test", tokens: M310Token())
    #expect(DataProvenance.sample(in: cloud) == nil)
    #expect(Backends.make(mode: cloud, transport: RecordingTransport()).provenance == .cloud)
    #expect(Backends.local.provenance == .onDevice)
  }

  // MARK: COPY

  @Test("COPY: new strings have no em dash, banned word, ADR 0016 term, exclamation mark or internal term")
  func newCopyRules() {
    let banned = try! Regex("(?i)\\b(generous|unlock|seamless|powerful|at scale|robust|everything you need|built for teams that)\\b")
    let adr0016 = try! Regex("(?i)" + "dry" + "[ _-]?" + "run|" + "preview" + " run")
    let internalTerms = try! Regex("\\b(MCP|token|tokens|LLM|gate|OCR|TCC|ingest|tenant|pseudonym)\\b")
    let all = NavigationCopy.all + AnalysisCopy.all + [NavigationCopy.backendLine(.local)]
    #expect(all.count > 20)
    for s in all {
      #expect(!s.contains("\u{2014}"), "em dash: \(s)")
      #expect(s.firstMatch(of: banned) == nil, "banned word: \(s)")
      #expect(s.firstMatch(of: adr0016) == nil, "ADR 0016 term: \(s)")
      #expect(s.firstMatch(of: internalTerms) == nil, "internal term: \(s)")
      #expect(!s.contains("!"), "exclamation mark: \(s)")
    }
  }

  @Test("COPY: captions are lowercase (the proper noun Mac aside) and facts are separate items, never one dotted string")
  func captionsLowercase() {
    for c in NavigationCopy.captions + AnalysisCopy.captions {
      let plain = c.replacingOccurrences(of: "Mac", with: "mac")
      #expect(plain == plain.lowercased(), "not lowercase: \(c)")
    }
    for item in AnalysisCopy.doneItems(Self.doneReport, repeats: 9) + AnalysisCopy.doneItems(Self.doneReport, repeats: nil) {
      #expect(!item.contains("·"), "dotted item: \(item)")
    }
    #expect(NavigationCopy.backendLine(.local) == "on this Mac only")
  }
}
