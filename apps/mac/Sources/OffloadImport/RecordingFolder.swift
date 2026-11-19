import Foundation

// Ported from PR #44 (RecordingFolder.swift) and wip/s34-brain (brain/src/import/folder.ts `detect`): what a picked
// folder holds. A screenwatch archive, screen recordings, screenshots, or nothing readable; an Offload data folder is
// refused, so imports never mix with live data.

public struct ImportRefusal: Error, Equatable, Sendable {
  public enum Code: String, CaseIterable, Sendable {
    case folderMissing = "folder_missing"
    case offloadData = "offload_data"
    case offloadHome = "offload_home"
    case noRecordings = "no_recordings"
  }

  public var code: Code
  /// One plain sentence for the person. Names the folder by its last component only.
  public var message: String

  public init(code: Code, message: String) {
    self.code = code
    self.message = message
  }

  public static func make(_ code: Code, folder: URL) -> ImportRefusal {
    let name = folder.lastPathComponent
    switch code {
    case .folderMissing:
      return ImportRefusal(code: code, message: "\(name) isn't there any more. Choose the folder again.")
    case .offloadData:
      return ImportRefusal(code: code, message: "This is Offload's own data folder. Choose the folder your screen recordings are saved in.")
    case .offloadHome:
      return ImportRefusal(code: code, message: "\(name) is an Offload data folder, not a recordings folder. Choose the folder your screen recordings or screenshots are in.")
    case .noRecordings:
      return ImportRefusal(code: code, message: "No screen recordings found in \(name). Offload reads screen recordings (mov, mp4), screenshots (png, jpg, heic, webp) or a screenwatch archive (days/DATE/log.jsonl).")
    }
  }
}

/// One readable file of a folder, with the time it was made.
public struct ScannedFile: Equatable, Sendable {
  public enum Kind: Equatable, Sendable { case video, image, screenwatchDay }
  public var url: URL
  public var kind: Kind
  /// The name's time, else nil (the modified time is used, minus the length for a recording).
  public var nameDate: Date?
  public var modified: Date
}

public struct FolderScan: Equatable, Sendable {
  public var folder: URL
  public var sourceKind: ImportSourceKind
  /// Oldest first.
  public var files: [ScannedFile]

  public var videos: [URL] { files.filter { $0.kind == .video }.map(\.url) }
  public var images: [URL] { files.filter { $0.kind == .image }.map(\.url) }
  public var screenwatchDays: [URL] { files.filter { $0.kind == .screenwatchDay }.map(\.url) }
}

public enum RecordingFolder {
  /// Folders below the one picked that are still read (the picked folder's own files are depth 0).
  public static let maxDepth = 3
  static let maxFiles = 20_000
  static let dayFile = #"^\d{4}-\d{2}-\d{2}\.jsonl(\.enc)?$"#
  static let dayFolder = #"^\d{4}-\d{2}-\d{2}$"#

  /// What `folder` holds. `protected` are Offload's own data folders: picking one (or a folder inside one) is
  /// refused, and a folder that holds one is read without it.
  public static func scan(_ folder: URL, protected: [URL], timeZone: TimeZone = .current) -> Result<FolderScan, ImportRefusal> {
    let fm = FileManager.default
    let dir = folder.standardizedFileURL
    var isDir: ObjCBool = false
    guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else {
      return .failure(.make(.folderMissing, folder: dir))
    }
    let guarded = protected.map { $0.standardizedFileURL.path }
    if guarded.contains(where: { dir.path == $0 || dir.path.hasPrefix($0 + "/") }) {
      return .failure(.make(.offloadData, folder: dir))
    }
    for d in [dir.appendingPathComponent("days"), dir] where names(in: d).contains(where: { matches($0, dayFile) }) {
      return .failure(.make(.offloadHome, folder: dir))
    }
    for d in [dir.appendingPathComponent("days"), dir] {
      let days = names(in: d).filter { matches($0, dayFolder) }.sorted().map { d.appendingPathComponent($0).appendingPathComponent("log.jsonl") }
        .filter { fm.fileExists(atPath: $0.path) }
      if !days.isEmpty {
        let files = days.map { ScannedFile(url: $0, kind: .screenwatchDay, nameDate: dayDate($0, timeZone: timeZone), modified: modified($0)) }
        return .success(FolderScan(folder: dir, sourceKind: .screenwatch, files: files))
      }
    }
    var found: [ScannedFile] = []
    walk(dir, depth: 0, guarded: Set(guarded), into: &found, timeZone: timeZone)
    guard !found.isEmpty else { return .failure(.make(.noRecordings, folder: dir)) }
    found.sort { a, b in
      let ta = a.nameDate ?? a.modified
      let tb = b.nameDate ?? b.modified
      return ta == tb ? a.url.lastPathComponent < b.url.lastPathComponent : ta < tb
    }
    let kind: ImportSourceKind = found.contains { $0.kind == .video } ? .videos : .screenshots
    return .success(FolderScan(folder: dir, sourceKind: kind, files: found))
  }

  /// Where macOS saves screen recordings (`com.apple.screencapture` `location`), else the Desktop.
  public static func suggested(home: URL, screencaptureLocation: String?) -> URL {
    guard let loc = screencaptureLocation?.trimmingCharacters(in: .whitespacesAndNewlines), !loc.isEmpty else {
      return home.appendingPathComponent("Desktop", isDirectory: true)
    }
    if loc.hasPrefix("~/") { return home.appendingPathComponent(String(loc.dropFirst(2)), isDirectory: true) }
    return URL(fileURLWithPath: loc, isDirectory: true)
  }

  static func walk(_ dir: URL, depth: Int, guarded: Set<String>, into found: inout [ScannedFile], timeZone: TimeZone) {
    let fm = FileManager.default
    for name in names(in: dir).sorted() {
      if name.hasPrefix(".") || found.count >= maxFiles { continue }
      let url = dir.appendingPathComponent(name)
      var isDir: ObjCBool = false
      guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
      if isDir.boolValue {
        let lower = name.lowercased()
        let bundle = lower.hasSuffix(".app") || lower.hasSuffix(".photoslibrary") || lower.hasSuffix(".bundle")
        if depth < maxDepth, !bundle, lower != "node_modules", !guarded.contains(url.standardizedFileURL.path) {
          walk(url, depth: depth + 1, guarded: guarded, into: &found, timeZone: timeZone)
        }
        continue
      }
      let kind: ScannedFile.Kind
      if RecordingName.isVideo(name) { kind = .video } else if RecordingName.isImage(name) { kind = .image } else { continue }
      found.append(ScannedFile(url: url, kind: kind, nameDate: RecordingName.date(fromName: name, timeZone: timeZone),
                               modified: modified(url)))
    }
  }

  static func names(in dir: URL) -> [String] {
    (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
  }

  static func matches(_ s: String, _ pattern: String) -> Bool {
    s.range(of: pattern, options: .regularExpression) != nil
  }

  static func modified(_ url: URL) -> Date {
    let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
    return (attrs?[.modificationDate] as? Date) ?? Date(timeIntervalSince1970: 0)
  }

  /// A screenwatch day folder's date at local midnight.
  static func dayDate(_ log: URL, timeZone: TimeZone) -> Date? {
    let parts = log.deletingLastPathComponent().lastPathComponent.split(separator: "-").compactMap { Int($0) }
    guard parts.count == 3 else { return nil }
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = timeZone
    return cal.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
  }
}

/// What screen 11 shows about a folder before anything is read.
public struct FolderSummary: Equatable, Sendable {
  public var sourceKind: ImportSourceKind
  /// Files, or days for a screenwatch archive.
  public var files: Int
  /// Lowercased, sorted, without the dot.
  public var extensions: [String]
  /// The recordings' total length; nil when there are none or it could not be read.
  public var totalSeconds: TimeInterval?
  public var first: Date?
  public var last: Date?

  public init(sourceKind: ImportSourceKind, files: Int, extensions: [String], totalSeconds: TimeInterval?,
              first: Date?, last: Date?) {
    self.sourceKind = sourceKind
    self.files = files
    self.extensions = extensions
    self.totalSeconds = totalSeconds
    self.first = first
    self.last = last
  }

  /// `duration` reads a recording's length (AVFoundation in the app).
  public static func make(scan: FolderScan, timeZone: TimeZone = .current, duration: (URL) -> TimeInterval?) -> FolderSummary {
    var total: TimeInterval = 0
    var anyLength = false
    var starts: [Date] = []
    for file in scan.files {
      switch file.kind {
      case .video:
        let length = duration(file.url)
        if let length { total += length; anyLength = true }
        starts.append(file.nameDate ?? file.modified.addingTimeInterval(-(length ?? 0)))
      case .image:
        starts.append(file.nameDate ?? file.modified)
      case .screenwatchDay:
        starts.append(file.nameDate ?? file.modified)
      }
    }
    let exts = scan.sourceKind == .screenwatch ? [] : Array(Set(scan.files.map { $0.url.pathExtension.lowercased() })).sorted()
    return FolderSummary(sourceKind: scan.sourceKind, files: scan.files.count, extensions: exts,
                         totalSeconds: anyLength ? total : nil, first: starts.min(), last: starts.max())
  }
}
