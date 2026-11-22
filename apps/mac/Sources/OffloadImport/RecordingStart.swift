import AVFoundation
import Foundation

// When a recording started (slice m3-05c-import-signals). Copied or synced files share one modified time, so "modified
// time minus length" put every such recording on the same minute (the 2026-11-22 end-to-end run). The start is now the
// container's creation date, else the name's time, else the modified time minus the length with a stable per-file
// order: recordings whose spans would overlap are laid end to end in (modified time, file) order, a gap apart.

/// The creation date a video container records, behind a protocol so tests inject it.
public protocol RecordingCreationDates: Sendable {
  func creationDate(of url: URL) -> Date?
}

/// No creation dates: every recording falls back to its name or its modified time.
public struct NoRecordingCreationDates: RecordingCreationDates {
  public init() {}
  public func creationDate(of url: URL) -> Date? { nil }
}

/// The container's creation date as AVFoundation reads it (the common creation date, else QuickTime's
/// `com.apple.quicktime.creationdate`), from its date value or its ISO 8601 text. Synchronous, like the frame reader:
/// the importer runs off the main actor, one file at a time.
public struct AVRecordingCreationDates: RecordingCreationDates {
  public init() {}

  public func creationDate(of url: URL) -> Date? {
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    let asset = AVURLAsset(url: url)
    var items: [AVMetadataItem] = []
    if let item = asset.creationDate { items.append(item) }
    items += AVMetadataItem.metadataItems(from: asset.metadata(forFormat: .quickTimeMetadata),
                                          filteredByIdentifier: .quickTimeMetadataCreationDate)
    for item in items {
      if let date = item.dateValue { return date }
      if let text = item.stringValue, let date = Self.date(fromISO: text) { return date }
    }
    return nil
  }

  static func date(fromISO text: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    if let date = formatter.date(from: text) { return date }
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.date(from: text)
  }
}

/// Where a recording's start came from.
public enum RecordingStartSource: String, Equatable, Sendable {
  case containerCreation = "container_creation"
  case name
  case modifiedOrdered = "modified_ordered"
}

/// What the importer knows about one recording's time.
public struct RecordingTimes: Equatable, Sendable {
  /// The file's name or path: orders recordings that share a modified time. Never stored.
  public var name: String
  /// The container's creation date.
  public var created: Date?
  /// The time the file name carries (`RecordingName.date(fromName:)`).
  public var nameDate: Date?
  public var modified: Date
  /// Seconds; nil when unknown (counts as 0).
  public var duration: TimeInterval?

  public init(name: String, created: Date?, nameDate: Date?, modified: Date, duration: TimeInterval?) {
    self.name = name
    self.created = created
    self.nameDate = nameDate
    self.modified = modified
    self.duration = duration
  }
}

public struct RecordingStart: Equatable, Sendable {
  public var start: Date
  public var source: RecordingStartSource

  public init(start: Date, source: RecordingStartSource) {
    self.start = start
    self.source = source
  }
}

public enum RecordingStartTime {
  /// Between recordings laid end to end: longer than the 120 s idle threshold, so each stays its own span.
  public static let sharedTimeGap: TimeInterval = 180

  /// The start of each recording, in the input's order; nil when it would end more than `futureSlack` after `now`
  /// (the server rejects that, ADR 0020).
  /// 1. The creation date, when it is a real time (2000 to 2100: QuickTime's 1904 zero and the Unix zero are not) and
  ///    the recording would not end in the future.
  /// 2. Else the name's time, on the same rule.
  /// 3. Else, over every such file, sorted by (modified time, name), from the last: end = min(modified, next start −
  ///    `gap`), start = end − duration. A file far from the others keeps its modified time minus its length; files
  ///    sharing a modified time are laid end to end, the last in name order ending at that time. The result depends
  ///    only on the files, not on the order they are listed in.
  public static func plan(_ files: [RecordingTimes], now: Date, futureSlack: TimeInterval = 600,
                          gap: TimeInterval = sharedTimeGap) -> [RecordingStart?] {
    let limit = now.addingTimeInterval(futureSlack)
    var out = [RecordingStart?](repeating: nil, count: files.count)
    var ordered: [Int] = []
    for (i, file) in files.enumerated() {
      let length = max(0, file.duration ?? 0)
      func usable(_ date: Date?) -> Date? {
        guard let date, date >= RecordingName.earliest, date <= RecordingName.latest,
              date.addingTimeInterval(length) <= limit else { return nil }
        return date
      }
      if let created = usable(file.created) {
        out[i] = RecordingStart(start: created, source: .containerCreation)
      } else if let named = usable(file.nameDate) {
        out[i] = RecordingStart(start: named, source: .name)
      } else if file.modified <= limit {
        ordered.append(i)
      }
    }
    ordered.sort { (files[$0].modified, files[$0].name) < (files[$1].modified, files[$1].name) }
    var nextStart: Date?
    for i in ordered.reversed() {
      var end = files[i].modified
      if let nextStart { end = min(end, nextStart.addingTimeInterval(-gap)) }
      let start = end.addingTimeInterval(-max(0, files[i].duration ?? 0))
      out[i] = RecordingStart(start: start, source: .modifiedOrdered)
      nextStart = start
    }
    return out
  }
}
