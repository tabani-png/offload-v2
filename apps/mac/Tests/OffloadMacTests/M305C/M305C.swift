import Foundation
import Testing
@testable import OffloadImport

// m3-05c-import-signals (slices/m3-05c-import-signals/SPEC.md). App cues for recordings without a menu bar and start
// times from container creation dates or a stable per-file order. Every test of this slice is a member of M305C, in
// extensions of it, one file per area. It reuses the m3-05 fakes (M305/M305.swift): OCR, the masker and the hasher
// are fakes; nothing touches TCC, the network, a window or a model.

@Suite struct M305C {}

// MARK: - Frames

/// A line whose box starts `y` px from the top of a 1280x800 frame.
func m305cLine(_ text: String, y: Double, x: Double = 100) -> OCRLine {
  OCRLine(text: text, box: OCRBox(x: x, y: y, width: 600, height: 16))
}

/// A window recording's frame (no menu bar): an optional tab or title line at the top, an optional URL bar line under
/// it, and one body line well below the window chrome.
func m305cWindow(tab: String? = nil, url: String? = nil, body: String) -> [OCRLine] {
  var lines: [OCRLine] = []
  if let tab { lines.append(m305cLine(tab, y: 10)) }
  if let url { lines.append(m305cLine(url, y: 50, x: 200)) }
  lines.append(m305cLine(body, y: 400))
  return lines
}

extension M305C {
  /// The cue of one frame of 1280x800 through the m3-05 fake masker.
  static func cue(_ lines: [OCRLine], masker: any ImportTextMasker = FakeMasker()) -> AppCue? {
    AppCues.classify(lines, frameHeight: 800, masker: masker)
  }

  static func ingest(_ script: M305Script, masker: FakeMasker = FakeMasker(), keyframes: FakeKeyframes? = nil,
                     exclusions: [ImportExclusionRule] = []) throws -> IngestResult {
    try M305.ingestor([script], masker: masker, keyframes: keyframes)
      .ingest(FakeRecording(script), startedAt: M305Clock.now.addingTimeInterval(-3600), importID: "imp", exclusions: exclusions)
  }

  /// Every app name a cue may give: the table's names and Browser.
  static var cueNames: Set<String> { Set(AppCues.rules.map(\.appName) + [AppCues.browser.appName]) }
}

// MARK: - Start times

/// Creation dates by file name, as the container metadata would give them.
struct M305CCreationDates: RecordingCreationDates {
  var dates: [String: Date]
  func creationDate(of url: URL) -> Date? { dates[url.lastPathComponent] }
}

/// The repository root (apps/mac/Tests/OffloadMacTests/M305C/ is four folders down from apps/mac).
enum M305CRepo {
  static let root: URL = M304Repo.macRoot.deletingLastPathComponent().deletingLastPathComponent()
  static let cueTable = root.appendingPathComponent("packages/contracts/rules/app-cues.json")
}

extension M305C {
  /// An importer over the m3-05 fakes whose readers give the injected creation dates.
  static func importer(_ fakes: M305Importer, created: [String: Date]) -> RecordingImporter {
    let scripts = fakes.scripts
    let readers = RecordingImporter.Readers(
      openVideo: { url in FakeRecording(scripts[url.lastPathComponent] ?? M305Script.twoApps(url.lastPathComponent)) },
      openImage: { url in ImportFrame(width: 1280, height: 800, tag: url.lastPathComponent) },
      creationDates: M305CCreationDates(dates: created)
    )
    return RecordingImporter(
      recognizer: M305AnyNameRecognizer(scripts: scripts, images: fakes.imageLines), masker: fakes.masker,
      hasher: M305AnyNameHasher(scripts: scripts), keyframes: fakes.keyframes, exclusions: fakes.exclusions,
      sink: fakes.sink, ledger: fakes.ledger, readers: readers, clock: fakes.clock, timeZone: M305Clock.utc
    )
  }

  static func run(_ fakes: M305Importer, folder: URL, created: [String: Date] = [:]) async -> ProgressLog {
    let log = ProgressLog()
    await importer(fakes, created: created).run(folder: folder) { log.add($0) }
    return log
  }

  static func times(_ name: String, created: Date? = nil, nameDate: Date? = nil, modified: Date,
                    duration: TimeInterval? = 60) -> RecordingTimes {
    RecordingTimes(name: name, created: created, nameDate: nameDate, modified: modified, duration: duration)
  }
}
