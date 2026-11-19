import CryptoKit
import Foundation
import Testing
@testable import OffloadImport
@testable import OffloadMac

// m3-05-recordings-import (slices/m3-05-recordings-import/SPEC.md). Every test of this slice is a member of M305; the
// tests live in extensions of it, one file per area. OCR, the masker, the perceptual hash and the keyframe renderer
// are m3-02's, so they are fakes here. Nothing touches TCC, the network, a window or a model.

@Suite struct M305 {}

/// A fixed clock: Thu 19 Nov 2026 12:00 UTC.
enum M305Clock {
  static let now = Date(timeIntervalSince1970: 1_795_089_600)
  static let utc = TimeZone(identifier: "UTC")!

  static func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int = 0, _ mi: Int = 0, _ s: Int = 0) -> Date {
    var c = DateComponents(year: y, month: mo, day: d, hour: h, minute: mi, second: s)
    c.timeZone = utc
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = utc
    return cal.date(from: c)!
  }
}

// MARK: - Files

enum M305Files {
  /// A fresh empty folder under the temporary directory.
  static func folder(_ name: String = "Recordings") -> URL {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("m305-\(UUID().uuidString.prefix(8))", isDirectory: true)
    let dir = root.appendingPathComponent(name, isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }

  static func remove(_ dir: URL) { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }

  /// Writes `bytes` bytes at `relative` (creating folders) and sets its modification time.
  @discardableResult
  static func put(_ dir: URL, _ relative: String, bytes: Int = 64, modified: Date = M305Clock.now.addingTimeInterval(-3600)) -> URL {
    let url = dir.appendingPathComponent(relative)
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? Data(repeating: 7, count: bytes).write(to: url)
    setModified(url, modified)
    return url
  }

  static func setModified(_ url: URL, _ date: Date) {
    try? FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
  }

  /// Every file under `dir`, relative, sorted.
  static func listing(_ dir: URL) -> [String] {
    guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil) else { return [] }
    var out: [String] = []
    for case let url as URL in e { out.append(String(url.path.dropFirst(dir.path.count))) }
    return out.sorted()
  }

  /// A screenwatch day: `days/<day>/log.jsonl`, one row every 5 s for `minutes` from `start` (UTC), each app for
  /// 10 minutes in turn.
  static func screenwatchDay(_ root: URL, _ day: String, start: (Int, Int), minutes: Int,
                             apps: [(app: String, window: String?, url: String?)] = []) {
    let parts = day.split(separator: "-").map { Int($0)! }
    let t0 = M305Clock.date(parts[0], parts[1], parts[2], start.0, start.1)
    var lines: [String] = []
    for i in 0..<(minutes * 12) {
      let at = t0.addingTimeInterval(TimeInterval(i * 5))
      let secs = Int(at.timeIntervalSince(M305Clock.date(parts[0], parts[1], parts[2])))
      let t = String(format: "%02d-%02d-%02d", secs / 3600, (secs / 60) % 60, secs % 60)
      var row: [String: Any] = ["t": t, "epoch": at.timeIntervalSince1970, "img": true]
      if !apps.isEmpty {
        let a = apps[(i / 120) % apps.count]
        row["app"] = a.app
        if let w = a.window { row["window"] = w }
        if let u = a.url { row["url"] = u }
      }
      let data = try! JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
      lines.append(String(decoding: data, as: UTF8.self))
    }
    let url = root.appendingPathComponent("days/\(day)/log.jsonl")
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    setModified(url, M305Clock.now.addingTimeInterval(-3600))
  }

  static let watchApps: [(app: String, window: String?, url: String?)] = [
    ("Google Chrome", "Re: Invoice 1042 from Amara Okafor - Gmail", "https://mail.google.com/mail/u/0/?token=SECRET123#inbox/FMfcgz"),
    ("Microsoft Excel", "Invoices 2026.xlsx", nil),
    ("1Password", "Bank login - Amara Okafor", nil),
    ("Slack", "#ops - Acme", nil),
  ]
}

// MARK: - OCR screens

/// A menu bar line (top band of a 1280x800 frame) and one body line.
func m305Screen(app: String, menus: String = "File Edit View Window Help", body: String) -> [OCRLine] {
  [OCRLine(text: "\u{F8FF} \(app) \(menus)", box: OCRBox(x: 8, y: 2, width: 600, height: 16)),
   OCRLine(text: body, box: OCRBox(x: 100, y: 300, width: 900, height: 20))]
}

/// One scene of a scripted recording: from `at` seconds on, these OCR lines and this perceptual hash.
struct M305Scene: Sendable {
  var at: TimeInterval
  var lines: [OCRLine]
  var hash: UInt64
}

/// A recording described by scenes. Sendable, so a @Sendable reader can build a fresh `FakeRecording` from it.
struct M305Script: Sendable {
  var id: String
  var duration: TimeInterval
  var scenes: [M305Scene]

  func tag(at t: TimeInterval) -> String {
    let i = scenes.lastIndex(where: { $0.at <= t }) ?? 0
    return "\(id)#\(i)"
  }

  var lines: [String: [OCRLine]] {
    var out: [String: [OCRLine]] = [:]
    for (i, s) in scenes.enumerated() { out["\(id)#\(i)"] = s.lines }
    return out
  }

  var hashes: [String: UInt64] {
    var out: [String: UInt64] = [:]
    for (i, s) in scenes.enumerated() { out["\(id)#\(i)"] = s.hash }
    return out
  }

  /// Safari, Safari again (same text), Numbers with a card number, Safari with new text. 60 s.
  static func twoApps(_ id: String = "rec") -> M305Script {
    M305Script(id: id, duration: 60, scenes: [
      M305Scene(at: 0, lines: m305Screen(app: "Safari", body: "Invoice 1042 from Acme"), hash: 0),
      M305Scene(at: 10, lines: m305Screen(app: "Safari", body: "Invoice 1042 from Acme"), hash: 0),
      M305Scene(at: 20, lines: m305Screen(app: "Numbers", body: "Card 4111 1111 1111 1111 paid"), hash: 0xFFFF_FFFF_FFFF_FFFF),
      M305Scene(at: 40, lines: m305Screen(app: "Safari", body: "Invoice 1043 from Acme"), hash: 0x0F0F_0F0F_0F0F_0F0F),
    ])
  }
}

final class FakeRecording: RecordingFrameSource {
  let script: M305Script
  private(set) var asked: [TimeInterval] = []
  init(_ script: M305Script) { self.script = script }
  var duration: TimeInterval { script.duration }
  func frame(at time: TimeInterval) throws -> ImportFrame? {
    asked.append(time)
    return ImportFrame(width: 1280, height: 800, tag: script.tag(at: time))
  }
}

struct ScriptedRecognizer: TextRecognizer {
  var lines: [String: [OCRLine]]
  init(_ scripts: [M305Script] = [], extra: [String: [OCRLine]] = [:]) {
    var all = extra
    for s in scripts { all.merge(s.lines) { a, _ in a } }
    lines = all
  }
  func recognize(_ frame: ImportFrame) throws -> [OCRLine] { lines[frame.tag] ?? [] }
}

struct ScriptedHasher: FrameHasher {
  var hashes: [String: UInt64]
  init(_ scripts: [M305Script]) {
    var all: [String: UInt64] = [:]
    for s in scripts { all.merge(s.hashes) { a, _ in a } }
    hashes = all
  }
  func hash(_ frame: ImportFrame) -> UInt64 { hashes[frame.tag] ?? 0 }
}

/// Stands in for the m3-02 masker: digit runs of 4 or more and the listed names become tokens.
final class FakeMasker: ImportTextMasker, @unchecked Sendable {
  private let lock = NSLock()
  private var seen: [String] = []
  /// Longest first, so a full name wins over its surname. Tokens hold no digits, so the digit rule leaves them alone.
  let names: [(String, String)] = [("Amara Okafor", "<person:h_aaaaaaaaaaaaaaaa>"), ("Okafor", "<person:h_bbbbbbbbbbbbbbbb>")]

  func mask(_ text: String) -> String {
    lock.lock()
    seen.append(text)
    lock.unlock()
    var out = text
    for (name, token) in names { out = out.replacingOccurrences(of: name, with: token) }
    return out.replacingOccurrences(of: #"\d{4,}"#, with: "<num>", options: .regularExpression)
  }

  var calls: [String] {
    lock.lock()
    defer { lock.unlock() }
    return seen
  }
}

final class FakeKeyframes: ImportKeyframeSink, @unchecked Sendable {
  private let lock = NSLock()
  private var kept: [ImportKeyframe] = []
  func keep(_ frame: ImportFrame, keyframe: ImportKeyframe) throws {
    lock.lock()
    kept.append(keyframe)
    lock.unlock()
  }
  var all: [ImportKeyframe] {
    lock.lock()
    defer { lock.unlock() }
    return kept
  }
}

/// A clock the test moves. `onSleep` runs after each sleep with the sleep's number (1, 2, ...) and the new time.
final class FakeClock: ImportClock, @unchecked Sendable {
  private let lock = NSLock()
  private var t: Date
  private var count = 0
  let onSleep: (@Sendable (Int, Date) -> Void)?
  init(_ start: Date = M305Clock.now, onSleep: (@Sendable (Int, Date) -> Void)? = nil) {
    t = start
    self.onSleep = onSleep
  }
  func now() -> Date {
    lock.lock()
    defer { lock.unlock() }
    return t
  }
  func sleep(seconds: TimeInterval) async {
    let (n, at) = advance(seconds)
    onSleep?(n, at)
  }
  /// Synchronous, because NSLock may not be used directly from an async function.
  private func advance(_ seconds: TimeInterval) -> (Int, Date) {
    lock.lock()
    defer { lock.unlock() }
    t = t.addingTimeInterval(seconds)
    count += 1
    return (count, t)
  }
  var sleeps: Int {
    lock.lock()
    defer { lock.unlock() }
    return count
  }
}

/// Collects progress values in order.
final class ProgressLog: @unchecked Sendable {
  private let lock = NSLock()
  private var items: [ImportProgress] = []
  func add(_ p: ImportProgress) {
    lock.lock()
    items.append(p)
    lock.unlock()
  }
  var all: [ImportProgress] {
    lock.lock()
    defer { lock.unlock() }
    return items
  }
  var warnings: [ImportWarning] {
    all.compactMap { if case .warning(let w) = $0 { return w } else { return nil } }
  }
  var report: ImportReport? {
    for p in all { if case .finished(let r) = p { return r } }
    return nil
  }
  var refusal: ImportRefusal? {
    for p in all { if case .refused(let r) = p { return r } }
    return nil
  }
}

struct M305ReadError: Error {}

// MARK: - Building an importer over fakes

struct M305Importer {
  var scripts: [String: M305Script] = [:]
  var broken: Set<String> = []
  var imageLines: [String: [OCRLine]] = [:]
  let masker = FakeMasker()
  let sink = InMemoryImportSink()
  let ledger = MemoryRecordingLedger()
  let keyframes = FakeKeyframes()
  var exclusions: any ImportExclusionSource = StaticImportExclusions([])
  var clock = FakeClock()
  var protected: [URL] = []

  /// Videos are looked up by file name in `scripts` (a 60 s two-app recording when missing); images give a frame
  /// tagged with their file name.
  func importer() -> RecordingImporter {
    let scripts = self.scripts
    let broken = self.broken
    let readers = RecordingImporter.Readers(
      openVideo: { url in
        let name = url.lastPathComponent
        if broken.contains(name) { throw M305ReadError() }
        return FakeRecording(scripts[name] ?? M305Script.twoApps(name))
      },
      openImage: { url in ImportFrame(width: 1280, height: 800, tag: url.lastPathComponent) }
    )
    return RecordingImporter(
      recognizer: M305AnyNameRecognizer(scripts: scripts, images: imageLines),
      masker: masker, hasher: M305AnyNameHasher(scripts: scripts), keyframes: keyframes,
      exclusions: exclusions, sink: sink, ledger: ledger, readers: readers, clock: clock,
      timeZone: M305Clock.utc, protected: protected
    )
  }

  func run(_ folder: URL) async -> ProgressLog {
    let log = ProgressLog()
    await importer().run(folder: folder) { log.add($0) }
    return log
  }
}

/// Recognizes frames of any scripted recording, and of a default two-app recording for unscripted names.
struct M305AnyNameRecognizer: TextRecognizer {
  var scripts: [String: M305Script]
  var images: [String: [OCRLine]]
  func recognize(_ frame: ImportFrame) throws -> [OCRLine] {
    if let lines = images[frame.tag] { return lines }
    guard let hash = frame.tag.lastIndex(of: "#") else { return [] }
    let name = String(frame.tag[..<hash])
    let script = scripts[name] ?? M305Script.twoApps(name)
    return script.lines[frame.tag] ?? []
  }
}

struct M305AnyNameHasher: FrameHasher {
  var scripts: [String: M305Script]
  func hash(_ frame: ImportFrame) -> UInt64 {
    guard let hash = frame.tag.lastIndex(of: "#") else { return 0 }
    let name = String(frame.tag[..<hash])
    return (scripts[name] ?? M305Script.twoApps(name)).hashes[frame.tag] ?? 0
  }
}

func m305Sha256(_ s: String) -> String {
  SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
}

/// The JSON of an observation, as a dictionary.
func m305JSON(_ o: ImportObservation) throws -> [String: Any] {
  let data = try JSONEncoder().encode(o)
  guard let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw M305ReadError() }
  return dict
}

// MARK: - UI fakes

@MainActor final class FakeFolderPicker: FolderPicker {
  var answer: URL?
  private(set) var asked: [URL?] = []
  func pickFolder(startingAt: URL?) -> URL? {
    asked.append(startingAt)
    return answer
  }
}

@MainActor final class FakeImportPanel: ImportPanelPresenter {
  private(set) var shown = 0
  private(set) var hidden = 0
  func show(_ model: RecordingsImportModel) { shown += 1 }
  func hide() { hidden += 1 }
}

@MainActor struct M305UI {
  let store = MemoryRecordingsFolderStore()
  let picker = FakeFolderPicker()
  let panel = FakeImportPanel()

  /// A model over the fakes; `importer` nil is this build's app (no OCR or masker yet).
  func model(importer: M305Importer?, suggested: URL) -> RecordingsImportModel {
    RecordingsImportModel(
      store: store, picker: picker, panel: panel, importer: importer?.importer(), sink: importer?.sink,
      ledger: importer?.ledger, durations: { _ in 600 }, suggestedFolder: suggested, protected: [],
      timeZone: M305Clock.utc
    )
  }
}
