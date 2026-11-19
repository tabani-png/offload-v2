import Foundation
import Testing
@testable import OffloadImport
@testable import OffloadMac

// A whole folder: sources (s34 import.test.ts SCREENWATCH, SCREENSHOTS), refusals (OFFLOAD HOME, EMPTY), the
// progress values (PROGRESS) and the rule that imports never mix with live data (PR #44 theCLIRefusesTheLiveHome).
extension M305 {
  // MARK: APART

  @Test("APART: imports never mix with live data, every object is source import with the import space's id")
  func everyObjectIsImported() async throws {
    let folder = M305Files.folder()
    defer { M305Files.remove(folder) }
    M305Files.put(folder, "Screen Recording 2026-11-13 at 9.41.07 AM.mov")
    M305Files.put(folder, "Screenshot 2026-11-13 at 10.15.32 AM.png")
    let fakes = M305Importer()
    let log = await fakes.run(folder)
    let space = try #require(log.report?.space)
    let all = fakes.sink.observations(in: space.id)
    #expect(!all.isEmpty)
    #expect(fakes.sink.spaces.count == 1)
    for o in all {
      let j = try m305JSON(o)
      #expect(j["source"] as? String == "import")
      #expect(j["import_id"] as? String == space.id)
    }
  }

  @Test("APART: theCLIRefusesTheLiveHome, restated: Offload's own data folder is refused and the sink is never opened")
  func ownDataFolderRefused() async throws {
    let root = M305Files.folder("Application Support")
    defer { M305Files.remove(root) }
    let data = root.appendingPathComponent("Offload", isDirectory: true)
    M305Files.put(data, "imports/Screen Recording 2026-11-13 at 9.41.07 AM.mov")
    var fakes = M305Importer()
    fakes.protected = [data]
    for folder in [data, data.appendingPathComponent("imports")] {
      let log = await fakes.run(folder)
      #expect(log.refusal?.code == .offloadData)
    }
    #expect(fakes.sink.spaces.isEmpty)
    // A folder that holds Offload's data folder is read without it.
    M305Files.put(root, "Screen Recording 2026-11-14 at 9.41.07 AM.mov")
    let scan = try RecordingFolder.scan(root, protected: [data], timeZone: M305Clock.utc).get()
    #expect(scan.videos.map(\.lastPathComponent) == ["Screen Recording 2026-11-14 at 9.41.07 AM.mov"])
  }

  @Test("APART: OffloadImport has no networking API, and the sink never receives a frame or pixels")
  func noNetworkNoPixels() throws {
    let sources = M304Repo.swiftSources("Sources/OffloadImport")
    #expect(!sources.isEmpty)
    for (path, text) in sources {
      for api in ["URLSession", "URLRequest", "NWConnection", "import Network", "CFNetwork", "CFStream"] {
        #expect(!text.contains(api), "\(path) uses \(api)")
      }
    }
    let sinkFile = try #require(sources.first { $0.text.contains("public protocol ImportSink") })
    let body = sinkFile.text.components(separatedBy: "public protocol ImportSink").last?.components(separatedBy: "\n}").first ?? ""
    #expect(!body.contains("ImportFrame"))
    #expect(!body.contains("CGImage"))
  }

  // MARK: SCREENWATCH

  @Test("SCREENWATCH: rows with app/window/url become masked focus events, a password manager keeps its name only")
  func screenwatchRows() async throws {
    let root = M305Files.folder("screenwatch")
    defer { M305Files.remove(root) }
    M305Files.screenwatchDay(root, "2026-09-01", start: (9, 0), minutes: 40, apps: M305Files.watchApps)
    M305Files.screenwatchDay(root, "2026-09-02", start: (9, 0), minutes: 40, apps: M305Files.watchApps)
    let fakes = M305Importer()
    let log = await fakes.run(root)
    let report = try #require(log.report)
    let space = try #require(report.space)
    #expect(space.sourceKind == .screenwatch)
    #expect(log.all.first == .started(.screenwatch, files: 2))
    #expect(report.filesRead == 2)
    #expect(report.moments == 2 * 40 * 12)
    let all = fakes.sink.observations(in: space.id)
    let focus = all.filter { $0.kind == .focus }
    #expect(Set(focus.compactMap(\.appName)) == ["Google Chrome", "Microsoft Excel", "1Password", "Slack"])
    let json = String(decoding: try JSONEncoder().encode(all), as: UTF8.self)
    for raw in ["Okafor", "1042", "SECRET123", "token=", "FMfcgz", "Bank login"] { #expect(!json.contains(raw), "\(raw)") }
    let gmail = try #require(focus.first { $0.appName == "Google Chrome" })
    #expect(gmail.host == "mail.google.com")
    #expect(gmail.appBundleID == "com.google.Chrome")
    let pw = try #require(focus.first { $0.appName == "1Password" })
    #expect(pw.title == nil)
    #expect(pw.host == nil)
    #expect(all.contains { $0.kind == .idleStart })
    #expect(report.firstDay == M305Clock.date(2026, 9, 1, 9, 0, 0))
  }

  @Test("SCREENWATCH: rows without app fields get one synthetic screen app; the archive's days/ folder works too")
  func screenwatchSynthetic() async throws {
    let root = M305Files.folder("screenwatch")
    defer { M305Files.remove(root) }
    M305Files.screenwatchDay(root, "2026-09-03", start: (14, 0), minutes: 30)
    let fakes = M305Importer()
    let log = await fakes.run(root.appendingPathComponent("days"))
    let space = try #require(log.report?.space)
    #expect(space.sourceKind == .screenwatch)
    let focus = fakes.sink.observations(in: space.id).filter { $0.kind == .focus }
    #expect(!focus.isEmpty)
    #expect(focus.allSatisfy { $0.appBundleID == ScreenwatchReader.syntheticAppID && $0.appName == ScreenwatchReader.syntheticAppName })
    #expect(ScreenwatchReader.syntheticAppID == "screenwatch.screen")
    #expect(ScreenwatchReader.syntheticAppName == "Screen")
  }

  @Test("SCREENWATCH: bad lines are counted, rows are unique by epoch and sorted")
  func screenwatchParse() {
    let text = """
    not json
    {"t":"09-00-05","epoch":1788253205}
    {"t":"09-00-00","epoch":1788253200,"app":"Slack"}
    {"t":"09-00-00","epoch":1788253200,"img":true}
    {"t":"bad","epoch":1788253210}
    """
    let parsed = ScreenwatchReader.parse(text)
    #expect(parsed.rows.count == 2)
    #expect(parsed.bad == 2)
    #expect(parsed.duplicates == 1)
    #expect(parsed.rows.first?.app == "Slack")
    #expect(parsed.rows.first?.img == true)
    #expect(parsed.rows.map(\.ts) == parsed.rows.map(\.ts).sorted())
  }

  @Test("SCREENWATCH: a gap over 2 minutes is idle: each run opens with idle_end and closes 120 s after its last row")
  func screenwatchRuns() {
    let t0 = M305Clock.date(2026, 9, 1, 9, 0, 0)
    let rows = [0, 5, 10, 400, 405].map { ScreenwatchRow(t: "09-00-00", ts: t0.addingTimeInterval(TimeInterval($0)), app: "Slack",
                                                         window: "#ops", url: nil, img: false) }
    let obs = ScreenwatchReader.observations(rows: rows, importID: "imp", masker: FakeMasker(), exclusions: [], ids: ULIDGenerator())
    let kinds = obs.map(\.kind)
    #expect(kinds == [.idleEnd, .focus, .idleStart, .idleEnd, .focus, .idleStart])
    #expect(obs[2].ts == t0.addingTimeInterval(10 + 120))
    #expect(obs[3].ts == t0.addingTimeInterval(400))
  }

  // MARK: SCREENSHOTS

  @Test("SCREENSHOTS: names give the time (macOS, CleanShot), else mtime; depth at most 3; nothing copied")
  func screenshots() async throws {
    let src = M305Files.folder("Shots")
    defer { M305Files.remove(src) }
    for i in 0..<6 { M305Files.put(src, "Screenshot 2026-10-20 at 10.\(10 + i).32 AM.png") }
    M305Files.put(src, "work/CleanShot 2026-10-20 at 10.30.00@2x.png")
    M305Files.put(src, "a/b/c/Screenshot 2026-10-20 at 10.31.00 AM.jpg")      // depth 3: read
    M305Files.put(src, "a/b/c/d/Screenshot 2026-10-21 at 10.31.00 AM.jpg")    // depth 4: not read
    M305Files.put(src, "holiday.png", modified: M305Clock.date(2026, 10, 18, 15, 0, 0))
    let before = M305Files.listing(src)
    let fakes = M305Importer()
    let log = await fakes.run(src)
    let report = try #require(log.report)
    let space = try #require(report.space)
    #expect(space.sourceKind == .screenshots)
    #expect(report.moments == 9)
    #expect(report.filesRead == 9)
    #expect(report.firstDay == M305Clock.date(2026, 10, 18, 15, 0, 0))
    let focusTimes = fakes.sink.observations(in: space.id).filter { $0.kind == .focus }.map(\.ts)
    #expect(focusTimes.contains(M305Clock.date(2026, 10, 20, 10, 30, 0)))
    #expect(!focusTimes.contains(M305Clock.date(2026, 10, 21, 10, 31, 0)))
    #expect(M305Files.listing(src) == before)
  }

  @Test("SCREENSHOTS: a folder with videos and screenshots is one import of kind videos")
  func mixedIsVideos() async throws {
    let src = M305Files.folder()
    defer { M305Files.remove(src) }
    M305Files.put(src, "standup.mov")
    M305Files.put(src, "Screenshot 2026-11-13 at 10.15.32 AM.png")
    let scan = try RecordingFolder.scan(src, protected: [], timeZone: M305Clock.utc).get()
    #expect(scan.sourceKind == .videos)
    #expect(scan.videos.count == 1 && scan.images.count == 1)
  }

  // MARK: FOLDER

  @Test("FOLDER: the suggested folder is where macOS saves screen recordings, else the Desktop")
  func defaultSuggestionIsWhereMacOSSavesRecordings() {
    let home = URL(fileURLWithPath: "/Users/m")
    #expect(RecordingFolder.suggested(home: home, screencaptureLocation: nil).path == "/Users/m/Desktop")
    #expect(RecordingFolder.suggested(home: home, screencaptureLocation: "  ").path == "/Users/m/Desktop")
    #expect(RecordingFolder.suggested(home: home, screencaptureLocation: "~/Movies/Rec").path == "/Users/m/Movies/Rec")
    #expect(RecordingFolder.suggested(home: home, screencaptureLocation: "/Volumes/X/Rec").path == "/Volumes/X/Rec")
  }

  @Test("FOLDER: the scan picks recordings oldest first and skips other files, hidden files and the ledger's folder")
  func folderScanPicksCandidatesOldestFirst() throws {
    let dir = M305Files.folder()
    defer { M305Files.remove(dir) }
    for n in ["Screen Recording 2026-11-13 at 9.41.07 AM.mov", "Screen Recording 2026-11-12 at 9.41.07 AM.mov", "notes.txt", ".tmp.mov"] {
      M305Files.put(dir, n)
    }
    M305Files.put(dir, ".hidden/Screen Recording 2026-11-10 at 9.41.07 AM.mov")
    let scan = try RecordingFolder.scan(dir, protected: [], timeZone: M305Clock.utc).get()
    #expect(scan.videos.map(\.lastPathComponent) == ["Screen Recording 2026-11-12 at 9.41.07 AM.mov",
                                                      "Screen Recording 2026-11-13 at 9.41.07 AM.mov"])
    #expect(scan.sourceKind == .videos)
  }

  @Test("FOLDER: the summary counts files, kinds, total length and days")
  func folderSummary() throws {
    let dir = M305Files.folder()
    defer { M305Files.remove(dir) }
    M305Files.put(dir, "Screen Recording 2026-11-05 at 9.00.00 AM.mov")
    M305Files.put(dir, "Screen Recording 2026-11-11 at 9.00.00 AM.mov")
    M305Files.put(dir, "clip.mp4", modified: M305Clock.date(2026, 11, 8, 12, 0, 0))
    let scan = try RecordingFolder.scan(dir, protected: [], timeZone: M305Clock.utc).get()
    let summary = FolderSummary.make(scan: scan, timeZone: M305Clock.utc) { _ in 600 }
    #expect(summary.files == 3)
    #expect(summary.extensions == ["mov", "mp4"])
    #expect(summary.totalSeconds == 1800)
    #expect(summary.first == M305Clock.date(2026, 11, 5, 9, 0, 0))
    #expect(summary.last == M305Clock.date(2026, 11, 11, 9, 0, 0))
  }

  @Test("FOLDER: screen 11 shows 12 files · .mov · 6 h 10 m · Nov 5 to 11 as separate items")
  func summaryItems() {
    let summary = FolderSummary(sourceKind: .videos, files: 12, extensions: ["mov"], totalSeconds: 6 * 3600 + 600,
                                first: M305Clock.date(2026, 11, 5, 9), last: M305Clock.date(2026, 11, 11, 17))
    #expect(RecordingsCopy.summaryItems(summary, timeZone: M305Clock.utc) == ["12 files", ".mov", "6 h 10 m", "Nov 5 to 11"])
    let one = FolderSummary(sourceKind: .videos, files: 1, extensions: ["mov", "mp4"], totalSeconds: 45 * 60,
                            first: M305Clock.date(2026, 10, 30), last: M305Clock.date(2026, 11, 2))
    #expect(RecordingsCopy.summaryItems(one, timeZone: M305Clock.utc) == ["1 file", ".mov, .mp4", "45 m", "Oct 30 to Nov 2"])
    let day = FolderSummary(sourceKind: .screenshots, files: 3, extensions: ["png"], totalSeconds: nil,
                            first: M305Clock.date(2026, 11, 5, 9), last: M305Clock.date(2026, 11, 5, 10))
    #expect(RecordingsCopy.summaryItems(day, timeZone: M305Clock.utc) == ["3 files", ".png", "Nov 5"])
    let watch = FolderSummary(sourceKind: .screenwatch, files: 32, extensions: [], totalSeconds: nil,
                              first: M305Clock.date(2026, 9, 1), last: M305Clock.date(2026, 10, 2))
    #expect(RecordingsCopy.summaryItems(watch, timeZone: M305Clock.utc) == ["32 days", "screenwatch archive", "Sep 1 to Oct 2"])
  }

  // MARK: REFUSE

  @Test("REFUSE: an Offload home (or its days/ folder) is refused with a clear message")
  func offloadHomeRefused() {
    let src = M305Files.folder("OldHome")
    defer { M305Files.remove(src) }
    M305Files.put(src, "days/2026-10-20.jsonl.enc")
    for folder in [src, src.appendingPathComponent("days")] {
      let r = RecordingFolder.scan(folder, protected: [], timeZone: M305Clock.utc)
      guard case .failure(let refusal) = r else { Issue.record("not refused: \(folder.lastPathComponent)"); continue }
      #expect(refusal.code == .offloadHome)
      #expect(refusal.message.contains("Offload"))
    }
  }

  @Test("REFUSE: EMPTY, a folder with nothing readable is no_recordings with its sentence")
  func emptyFolderIsNoRecordings() async {
    let src = M305Files.folder("Stuff")
    defer { M305Files.remove(src) }
    M305Files.put(src, "notes.txt")
    let fakes = M305Importer()
    let log = await fakes.run(src)
    #expect(log.refusal?.code == .noRecordings)
    #expect(log.refusal?.message == "No screen recordings found in Stuff. Offload reads screen recordings (mov, mp4), screenshots (png, jpg, heic, webp) or a screenwatch archive (days/DATE/log.jsonl).")
    #expect(fakes.sink.spaces.isEmpty)
  }

  @Test("REFUSE: a folder that is not there is folder_missing")
  func missingFolder() {
    let src = M305Files.folder()
    defer { M305Files.remove(src) }
    let r = RecordingFolder.scan(src.appendingPathComponent("nope"), protected: [], timeZone: M305Clock.utc)
    guard case .failure(let refusal) = r else { Issue.record("not refused"); return }
    #expect(refusal.code == .folderMissing)
    #expect(ImportRefusal.Code.allCases.map(\.rawValue) == ["folder_missing", "offload_data", "offload_home", "no_recordings"])
  }

  // MARK: PROGRESS

  @Test("PROGRESS: started, reading file n of N for each file, then finished with the counts")
  func progressOrder() async throws {
    let folder = M305Files.folder()
    defer { M305Files.remove(folder) }
    M305Files.put(folder, "Screen Recording 2026-11-12 at 9.41.07 AM.mov")
    M305Files.put(folder, "Screen Recording 2026-11-13 at 9.41.07 AM.mov")
    let fakes = M305Importer()
    let log = await fakes.run(folder)
    let report = try #require(log.report)
    #expect(Array(log.all.prefix(3)) == [.started(.videos, files: 2), .reading(file: 1, of: 2), .reading(file: 2, of: 2)])
    #expect(log.all.last == .finished(report))
    #expect(report.filesRead == 2)
    #expect(report.moments == 24)
    #expect(report.observations == fakes.sink.observations(in: try #require(report.space).id).count)
    #expect(report.firstDay == M305Clock.date(2026, 11, 12, 9, 41, 7))
  }

  @Test("PROGRESS: a file still being written waits for the gate, then is read")
  func waitsForTheGate() async throws {
    let folder = M305Files.folder()
    defer { M305Files.remove(folder) }
    let url = M305Files.put(folder, "Screen Recording 2026-11-19 at 11.00.00 AM.mov", bytes: 10, modified: M305Clock.now)
    var fakes = M305Importer()
    fakes.clock = FakeClock(M305Clock.now) { n, at in
      guard n == 1 else { return }
      // The recorder writes more during the first wait.
      if let h = try? FileHandle(forWritingTo: url) {
        _ = h.seekToEndOfFile()
        h.write(Data(repeating: 1, count: 10))
        try? h.close()
      }
      M305Files.setModified(url, at)
    }
    let log = await fakes.run(folder)
    #expect(log.report?.filesRead == 1)
    #expect(fakes.clock.sleeps >= 2)
    #expect(log.warnings.isEmpty)
  }

  @Test("PROGRESS: a file that keeps growing is left for next time with a warning")
  func keepsGrowing() async {
    let folder = M305Files.folder()
    defer { M305Files.remove(folder) }
    let url = M305Files.put(folder, "Screen Recording 2026-11-19 at 11.00.00 AM.mov", bytes: 10, modified: M305Clock.now)
    var fakes = M305Importer()
    fakes.clock = FakeClock(M305Clock.now) { _, at in
      if let h = try? FileHandle(forWritingTo: url) {
        _ = h.seekToEndOfFile()
        h.write(Data(repeating: 1, count: 10))
        try? h.close()
      }
      M305Files.setModified(url, at)
    }
    let log = await fakes.run(folder)
    #expect(log.warnings == [.stillWriting(files: 1)])
    #expect(log.report?.filesRead == 0)
    #expect(fakes.ledger.entries.isEmpty)
  }

  @Test("PROGRESS: a file read once is skipped next time; the sink opens one import space")
  func readOnce() async throws {
    let folder = M305Files.folder()
    defer { M305Files.remove(folder) }
    M305Files.put(folder, "Screen Recording 2026-11-12 at 9.41.07 AM.mov")
    M305Files.put(folder, "Screen Recording 2026-11-13 at 9.41.07 AM.mov")
    let fakes = M305Importer()
    _ = await fakes.run(folder)
    let again = await fakes.run(folder)
    let report = try #require(again.report)
    #expect(report.filesRead == 0)
    #expect(report.skipped == 2)
    #expect(report.space == nil)
    #expect(fakes.sink.spaces.count == 1)
    #expect(fakes.ledger.entries.count == 2)
  }

  @Test("PROGRESS: a file that cannot be read is reported and the others are still read")
  func failingFileDoesNotStopOthers() async throws {
    let folder = M305Files.folder()
    defer { M305Files.remove(folder) }
    M305Files.put(folder, "Screen Recording 2026-11-12 at 9.41.07 AM.mov")
    M305Files.put(folder, "broken.mov", modified: M305Clock.date(2026, 11, 13, 9, 0, 0))
    var fakes = M305Importer()
    fakes.broken = ["broken.mov"]
    let log = await fakes.run(folder)
    let report = try #require(log.report)
    #expect(report.filesRead == 1)
    #expect(report.failed == 1)
    #expect(log.warnings == [.unreadable(file: "broken.mov")])
    #expect(fakes.ledger.entries.count == 1)
  }
}
