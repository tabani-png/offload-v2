import Foundation

// Where recordings usually are, so the Recordings screen can start from the right folder. Existence only: no folder
// is listed before the screen appears (m3-05's rule), so this checks `fileExists` and nothing more.

public struct RecordingFolderCandidate: Equatable, Sendable {
  public enum Kind: String, Equatable, Sendable {
    /// `~/screenwatch` holding `days/`.
    case screenwatch
    /// `~/screenwatch` without `days/` yet.
    case folder
    /// macOS Screen Recording and Screenshot's save location (`com.apple.screencapture` `location`).
    case screenRecordings
    case desktop
    /// QuickTime's default.
    case movies
  }

  public var url: URL
  public var kind: Kind

  public init(url: URL, kind: Kind) {
    self.url = url
    self.kind = kind
  }
}

public enum DefaultRecordingFolders {
  /// In order, only those that exist: `~/screenwatch`, the screencapture location (`~/` expanded), `~/Desktop`,
  /// `~/Movies`. Each folder once; Offload's own data folder (and anything inside it) never.
  public static func candidates(home: URL, screencaptureLocation: String?, protected: [URL] = [],
                                exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) })
    -> [RecordingFolderCandidate] {
    var list: [RecordingFolderCandidate] = []
    let screenwatch = home.appendingPathComponent("screenwatch", isDirectory: true)
    let hasDays = exists(screenwatch.appendingPathComponent("days", isDirectory: true).path)
    list.append(RecordingFolderCandidate(url: screenwatch, kind: hasDays ? .screenwatch : .folder))
    if let loc = screencaptureLocation?.trimmingCharacters(in: .whitespacesAndNewlines), !loc.isEmpty {
      let url: URL
      if loc.hasPrefix("~/") {
        url = home.appendingPathComponent(String(loc.dropFirst(2)), isDirectory: true)
      } else if loc == "~" {
        url = home
      } else {
        url = URL(fileURLWithPath: loc, isDirectory: true)
      }
      list.append(RecordingFolderCandidate(url: url, kind: .screenRecordings))
    }
    list.append(RecordingFolderCandidate(url: home.appendingPathComponent("Desktop", isDirectory: true), kind: .desktop))
    list.append(RecordingFolderCandidate(url: home.appendingPathComponent("Movies", isDirectory: true), kind: .movies))

    let guarded = protected.map { $0.standardizedFileURL.path }
    var seen = Set<String>()
    var out: [RecordingFolderCandidate] = []
    for c in list {
      let path = c.url.standardizedFileURL.path
      if guarded.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) { continue }
      guard !seen.contains(path), exists(path) else { continue }
      seen.insert(path)
      out.append(c)
    }
    return out
  }

  /// The first candidate, used only when no folder was chosen.
  public static func preferred(home: URL, screencaptureLocation: String?, protected: [URL] = [],
                               exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> RecordingFolderCandidate? {
    candidates(home: home, screencaptureLocation: screencaptureLocation, protected: protected, exists: exists).first
  }
}
