import Foundation
import Testing
@testable import OffloadImport
@testable import OffloadMac

// One recording through OCR, the masker, the exclusions and the keyframe throttle (PR #44 S34IngestTests), with
// real timestamps (no rebasing).
extension M305 {
  static func ingestor(_ scripts: [M305Script], masker: FakeMasker = FakeMasker(), keyframes: FakeKeyframes? = nil) -> RecordingIngestor {
    RecordingIngestor(recognizer: ScriptedRecognizer(scripts), masker: masker, hasher: ScriptedHasher(scripts),
                      keyframes: keyframes)
  }

  static func of(_ kind: ImportObservation.Kind, _ result: IngestResult) -> [ImportObservation] {
    result.observations.filter { $0.kind == kind }
  }

  // MARK: INGEST

  @Test("INGEST: idle_end, focus, text and idle_start at recording time (writesFocusOcrAndIdleBracketsAtRecordingTime)")
  func bracketsAtRecordingTime() throws {
    let script = M305Script.twoApps()
    let start = M305Clock.now.addingTimeInterval(-3600)
    let r = try M305.ingestor([script]).ingest(FakeRecording(script), startedAt: start, importID: "imp", exclusions: [])
    #expect(r.observations.first?.kind == .idleEnd)
    #expect(r.observations.first?.ts == start)
    let focus = M305.of(.focus, r)
    #expect(focus.map(\.appName) == ["Safari", "Numbers", "Safari"])
    #expect(focus.map(\.appBundleID) == ["com.apple.Safari", "com.apple.iWork.Numbers", "com.apple.Safari"])
    #expect(focus.map(\.ts) == [0, 20, 40].map { start.addingTimeInterval($0) })
    let text = M305.of(.textSnapshot, r)
    #expect(text.count == 3)
    #expect(text.allSatisfy { $0.appBundleID != nil && $0.textHash?.count == 64 })
    // The recording's end plus the idle threshold: readers backdate idle_start by 120 s.
    #expect(r.observations.last?.kind == .idleStart)
    #expect(r.observations.last?.ts == start.addingTimeInterval(60 + 120))
    #expect(r.observations.allSatisfy { $0.id.count == 26 && $0.importID == "imp" })
    #expect(r.observations.map(\.ts) == r.observations.map(\.ts).sorted())
    #expect(r.frames == 12)
  }

  @Test("INGEST: the same text in the same app is not written twice")
  func sameTextOnce() throws {
    let script = M305Script(id: "same", duration: 30, scenes: [
      M305Scene(at: 0, lines: m305Screen(app: "Notes", body: "Plan for Monday"), hash: 0),
    ])
    let r = try M305.ingestor([script]).ingest(FakeRecording(script), startedAt: M305Clock.now.addingTimeInterval(-600),
                                               importID: "imp", exclusions: [])
    #expect(r.frames == 6)
    #expect(M305.of(.textSnapshot, r).count == 1)
    #expect(M305.of(.focus, r).count == 1)
  }

  @Test("INGEST: keyframes are at least 20 s apart in recording time and only when the picture changed")
  func keyframesThrottledByRecordingTime() throws {
    let script = M305Script.twoApps()
    let keyframes = FakeKeyframes()
    let start = M305Clock.now.addingTimeInterval(-600)
    let r = try M305.ingestor([script], keyframes: keyframes).ingest(FakeRecording(script), startedAt: start,
                                                                       importID: "imp", exclusions: [])
    let kept = keyframes.all
    #expect(kept.count >= 2)
    #expect(r.keyframes == kept.count)
    for (a, b) in zip(kept, kept.dropFirst()) { #expect(b.ts.timeIntervalSince(a.ts) >= 20) }
    #expect(kept.allSatisfy { !$0.appName.isEmpty && $0.importID == "imp" })
    var throttle = KeyframeThrottle()
    #expect(throttle.keep(at: 0, hash: 0))
    #expect(!throttle.keep(at: 25, hash: 1))             // the picture did not change enough
    #expect(!throttle.keep(at: 10, hash: .max))          // too soon
    #expect(throttle.keep(at: 30, hash: .max))
  }

  @Test("INGEST: keyframes off writes none")
  func keyframesOffWritesNone() throws {
    let script = M305Script.twoApps()
    let r = try M305.ingestor([script]).ingest(FakeRecording(script), startedAt: M305Clock.now.addingTimeInterval(-600),
                                               importID: "imp", exclusions: [])
    #expect(r.keyframes == 0)
  }

  @Test("INGEST: an old recording keeps its real time (no rebasing into the retention window)")
  func realTimeIsKept() throws {
    let script = M305Script.twoApps()
    let old = M305Clock.now.addingTimeInterval(-30 * 86400)
    let r = try M305.ingestor([script]).ingest(FakeRecording(script), startedAt: old, importID: "imp", exclusions: [])
    #expect(r.observations.first?.ts == old)
    #expect(r.observations.allSatisfy { $0.ts < old.addingTimeInterval(200) })
  }

  @Test("INGEST: a recording whose time would be in the future is skipped with a warning")
  func futureTimeIsSkipped() async {
    let folder = M305Files.folder()
    defer { M305Files.remove(folder) }
    M305Files.put(folder, "Screen Recording 2026-11-21 at 9.41.07 AM.mov", modified: M305Clock.now.addingTimeInterval(86400))
    let fakes = M305Importer()
    let log = await fakes.run(folder)
    #expect(log.warnings == [.futureTime(file: "Screen Recording 2026-11-21 at 9.41.07 AM.mov")])
    #expect(log.report?.filesRead == 0)
    #expect(fakes.ledger.entries.isEmpty)
  }

  @Test("INGEST: with no name time a recording starts at its modified time minus its length")
  func modifiedTimeMinusLength() async throws {
    let folder = M305Files.folder()
    defer { M305Files.remove(folder) }
    let end = M305Clock.date(2026, 11, 18, 17, 0, 0)
    M305Files.put(folder, "standup.mov", modified: end)
    let fakes = M305Importer()
    let log = await fakes.run(folder)
    let space = try #require(log.report?.space)
    let first = try #require(fakes.sink.observations(in: space.id).first)
    #expect(first.kind == .idleEnd)
    #expect(first.ts == end.addingTimeInterval(-60))
  }

  // MARK: MASK

  @Test("MASK: ocrTextIsMaskedBeforeItIsWritten, the masker sees the text before any observation holds it")
  func ocrTextIsMaskedBeforeItIsWritten() throws {
    let script = M305Script.twoApps()
    let masker = FakeMasker()
    let r = try M305.ingestor([script], masker: masker).ingest(FakeRecording(script), startedAt: M305Clock.now.addingTimeInterval(-600),
                                                                importID: "imp", exclusions: [])
    let texts = M305.of(.textSnapshot, r).compactMap(\.text)
    #expect(!texts.joined().contains("4111"))
    #expect(!texts.joined().contains("1042"))
    #expect(texts.contains { $0.contains("<num>") })
    #expect(masker.calls.contains { $0.contains("4111") })
    // The menu bar band is not body text.
    #expect(!texts.joined().contains("File Edit View"))
  }

  @Test("MASK: screenwatch titles are masked and URLs are reduced to their host")
  func screenwatchTitlesMasked() throws {
    let masker = FakeMasker()
    let at = M305Clock.date(2026, 9, 1, 9, 0, 0)
    let rows = [ScreenwatchRow(t: "09-00-00", ts: at, app: "Google Chrome", window: "Re: Invoice 1042 from Amara Okafor - Gmail",
                               url: "https://mail.google.com/mail/u/0/?token=SECRET123#inbox/FMfcgz", img: true)]
    let obs = ScreenwatchReader.observations(rows: rows, importID: "imp", masker: masker, exclusions: [], ids: ULIDGenerator())
    let focus = try #require(obs.first { $0.kind == .focus })
    #expect(focus.host == "mail.google.com")
    #expect(focus.title == "Re: Invoice <num> from <person:h_aaaaaaaaaaaaaaaa> - Gmail")
    let json = String(decoding: try JSONEncoder().encode(obs), as: UTF8.self)
    for raw in ["Okafor", "1042", "SECRET123", "token=", "FMfcgz", "/mail/u/0"] { #expect(!json.contains(raw), "\(raw)") }
  }

  @Test("MASK: text and titles are clipped to the contract limits after masking")
  func clippedToLimits() {
    let long = String(repeating: "a", count: 9000)
    #expect(ImportWire.clip(long, maxUTF16: 8000).utf16.count == 8000)
    let emoji = String(repeating: "\u{1F600}", count: 300)   // 2 UTF-16 units each
    let clipped = ImportWire.clip(emoji, maxUTF16: 511)
    #expect(clipped.utf16.count == 510)
    #expect(ImportWire.limits.text == 8000 && ImportWire.limits.title == 512)
    #expect(ImportWire.limits.appName == 256 && ImportWire.limits.appBundleID == 255)
  }

  // MARK: EXCLUDE

  @Test("EXCLUDE: excludedAppsGetNoText, a password manager keeps its time but no text and no keyframe")
  func excludedAppsGetNoText() throws {
    let script = M305Script(id: "pw", duration: 20, scenes: [
      M305Scene(at: 0, lines: m305Screen(app: "1Password", body: "hunter2 vault"), hash: 0),
    ])
    let keyframes = FakeKeyframes()
    let r = try M305.ingestor([script], keyframes: keyframes).ingest(FakeRecording(script), startedAt: M305Clock.now.addingTimeInterval(-600),
                                                                       importID: "imp", exclusions: [])
    #expect(M305.of(.textSnapshot, r).isEmpty)
    #expect(M305.of(.focus, r).map(\.appName) == ["1Password"])
    #expect(keyframes.all.isEmpty)
    let json = String(decoding: try JSONEncoder().encode(r.observations), as: UTF8.self)
    #expect(!json.contains("hunter2"))
  }

  @Test("EXCLUDE: theUsersExclusionsApplyToRecordings, through m3-04's Never watch store")
  func theUsersExclusionsApplyToRecordings() throws {
    let store = NeverWatchStore()
    store.add([Exclusion(kind: .bundleID, value: "com.apple.iWork.Numbers")])
    let rules = NeverWatchImportExclusions(source: store).currentRules()
    #expect(rules.contains(ImportExclusionRule(kind: .bundleID, value: "com.apple.iWork.Numbers")))
    let script = M305Script.twoApps()
    let keyframes = FakeKeyframes()
    let r = try M305.ingestor([script], keyframes: keyframes).ingest(FakeRecording(script), startedAt: M305Clock.now.addingTimeInterval(-600),
                                                                       importID: "imp", exclusions: rules)
    #expect(M305.of(.textSnapshot, r).allSatisfy { $0.appBundleID != "com.apple.iWork.Numbers" })
    #expect(keyframes.all.allSatisfy { $0.appName != "Numbers" })
    #expect(M305.of(.focus, r).contains { $0.appName == "Numbers" })   // time still counts, like live
  }

  @Test("EXCLUDE: a Never watch entry added during an import applies from the next file")
  func exclusionsReloadPerFile() async throws {
    let folder = M305Files.folder()
    defer { M305Files.remove(folder) }
    M305Files.put(folder, "Screen Recording 2026-11-13 at 9.00.00 AM.mov")
    M305Files.put(folder, "Screen Recording 2026-11-13 at 10.00.00 AM.mov")
    let store = NeverWatchStore()
    var fakes = M305Importer()
    fakes.exclusions = NeverWatchImportExclusions(source: store)
    let importer = fakes.importer()
    let log = ProgressLog()
    await importer.run(folder: folder) { p in
      log.add(p)
      // When the second file starts, the person adds Numbers: the first file was read without it.
      if case .reading(file: 2, of: _) = p { store.add([Exclusion(kind: .bundleID, value: "com.apple.iWork.Numbers")]) }
    }
    let space = try #require(log.report?.space)
    let texts = fakes.sink.observations(in: space.id).filter { $0.kind == .textSnapshot }
    let numbers = texts.filter { $0.appBundleID == "com.apple.iWork.Numbers" }
    #expect(numbers.count == 1)   // only from the first file
    #expect(texts.count == 5)     // Safari twice in each file, Numbers once in the first
  }

  @Test("EXCLUDE: built-ins skip password managers by name or bundle id, banking hosts and private windows")
  func builtIns() {
    #expect(ImportExclusions.isExcluded(bundleID: "recording.bitwarden", appName: "Bitwarden", title: nil, host: nil, rules: []))
    #expect(ImportExclusions.isExcluded(bundleID: "com.1password.1password", appName: "1Password 8", title: nil, host: nil, rules: []))
    #expect(ImportExclusions.isExcluded(bundleID: "com.google.Chrome", appName: "Google Chrome", title: nil, host: "secure.chase.com", rules: []))
    #expect(ImportExclusions.isExcluded(bundleID: "com.apple.Safari", appName: "Safari", title: "Private Browsing", host: nil, rules: []))
    #expect(!ImportExclusions.isExcluded(bundleID: "com.apple.Safari", appName: "Safari", title: "Docs", host: "example.com", rules: []))
    let host = ImportExclusionRule(kind: .host, value: "mail.google.com")
    #expect(ImportExclusions.isExcluded(bundleID: "com.google.Chrome", appName: "Google Chrome", title: nil, host: "mail.google.com", rules: [host]))
    let title = ImportExclusionRule(kind: .titleContains, value: "payroll")
    #expect(ImportExclusions.isExcluded(bundleID: "x", appName: "X", title: "Q3 Payroll.xlsx", host: nil, rules: [title]))
  }

  // MARK: Review 1

  static func oneScene(_ id: String, _ lines: [OCRLine]) -> M305Script {
    M305Script(id: id, duration: 10, scenes: [M305Scene(at: 0, lines: lines, hash: 0)])
  }

  @Test("MASK: window text in the top band (no menu bar) never becomes an app name; the app is unknown")
  func bandTextIsNotAnAppName() throws {
    let lines = [OCRLine(text: "Okafor_contract.pdf", box: OCRBox(x: 400, y: 4, width: 300, height: 16)),
                 OCRLine(text: "Terms and payment", box: OCRBox(x: 100, y: 300, width: 600, height: 20))]
    let script = M305.oneScene("band", lines)
    let r = try M305.ingestor([script]).ingest(FakeRecording(script), startedAt: M305Clock.now.addingTimeInterval(-600),
                                               importID: "imp", exclusions: [])
    let focus = M305.of(.focus, r)
    #expect(focus.map(\.appName) == ["Screen"])
    #expect(focus.map(\.appBundleID) == ["recording.unknown"])
    let json = String(decoding: try JSONEncoder().encode(r.observations), as: UTF8.self)
    #expect(!json.contains("contract"))
    #expect(!json.lowercased().contains("okafor"))
  }

  @Test("MASK: a menu bar name the masker would change is not written; the app is unknown")
  func maskedNameIsNotWritten() throws {
    let script = M305.oneScene("masked", m305Screen(app: "Report 2026", menus: "File Edit View", body: "Totals"))
    let masker = FakeMasker()
    let r = try M305.ingestor([script], masker: masker).ingest(FakeRecording(script), startedAt: M305Clock.now.addingTimeInterval(-600),
                                                                importID: "imp", exclusions: [])
    #expect(M305.of(.focus, r).map(\.appName) == ["Screen"])
    #expect(M305.of(.focus, r).map(\.appBundleID) == ["recording.unknown"])
    #expect(masker.calls.contains("Report 2026"))
    let json = String(decoding: try JSONEncoder().encode(r.observations), as: UTF8.self)
    #expect(!json.contains("2026"))
  }

  @Test("EXCLUDE: a banking host or a private window seen in a recording gets no text and no keyframe (built-ins)")
  func builtInsOnRecordings() throws {
    let bank = M305.oneScene("bank", m305Screen(app: "Safari", body: "https://secure.chase.com/accounts") +
      [OCRLine(text: "Balance 9876 available", box: OCRBox(x: 100, y: 340, width: 600, height: 20))])
    let priv = M305.oneScene("priv", m305Screen(app: "Safari", body: "Private Browsing") +
      [OCRLine(text: "Search for gifts", box: OCRBox(x: 100, y: 340, width: 600, height: 20))])
    for script in [bank, priv] {
      let keyframes = FakeKeyframes()
      let r = try M305.ingestor([script], keyframes: keyframes).ingest(FakeRecording(script), startedAt: M305Clock.now.addingTimeInterval(-600),
                                                                         importID: "imp", exclusions: [])
      #expect(M305.of(.textSnapshot, r).isEmpty, "\(script.id)")
      #expect(keyframes.all.isEmpty, "\(script.id)")
      #expect(M305.of(.focus, r).map(\.appName) == ["Safari"], "\(script.id)")
    }
  }

  @Test("EXCLUDE: the person's host and title rules apply to what a recording shows")
  func userHostAndTitleRulesOnRecordings() throws {
    let mail = M305.oneScene("mail", m305Screen(app: "Safari", body: "mail.example.org/inbox") +
      [OCRLine(text: "Lunch on Friday?", box: OCRBox(x: 100, y: 340, width: 600, height: 20))])
    let payroll = M305.oneScene("pay", m305Screen(app: "Numbers", body: "Q3 Payroll review"))
    let plain = M305.oneScene("plain", m305Screen(app: "Safari", body: "docs.example.com/guide"))
    let rules = [ImportExclusionRule(kind: .host, value: "example.org"), ImportExclusionRule(kind: .titleContains, value: "payroll")]
    for script in [mail, payroll] {
      let r = try M305.ingestor([script]).ingest(FakeRecording(script), startedAt: M305Clock.now.addingTimeInterval(-600),
                                                 importID: "imp", exclusions: rules)
      #expect(M305.of(.textSnapshot, r).isEmpty, "\(script.id)")
      #expect(M305.of(.focus, r).count == 1, "\(script.id)")
    }
    let r = try M305.ingestor([plain]).ingest(FakeRecording(plain), startedAt: M305Clock.now.addingTimeInterval(-600),
                                              importID: "imp", exclusions: rules)
    #expect(M305.of(.textSnapshot, r).count == 1)
    #expect(ImportExclusions.hosts(in: ["Go to https://Secure.Chase.com/login, then", "nothing here"]) == ["secure.chase.com"])
  }
}
