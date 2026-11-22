import Foundation
import OffloadImport

// The on-device import sink: an import's masked observations are kept on this Mac only, one JSON line each, in
// `OnDevice/imports/<import_id>.jsonl` (folder 0700, files 0600, file protection until first unlock, excluded from
// backups).
// It sends nothing: it is not the uploader, and in `.local` backend mode nothing leaves the Mac. The masked text itself
// is not kept (insights need only that the text changed, so only its hash is), no pixels, no file names or paths.

/// One stored line. Snake case keys, the m1-02 observation names, without `text`.
public struct StoredObservation: Codable, Equatable, Sendable {
  public var id: String
  /// RFC 3339 in UTC with milliseconds.
  public var ts: String
  public var kind: String
  public var importID: String
  public var appBundleID: String?
  public var appName: String?
  public var title: String?
  public var host: String?
  public var textHash: String?

  public init(id: String, ts: String, kind: String, importID: String, appBundleID: String? = nil, appName: String? = nil,
              title: String? = nil, host: String? = nil, textHash: String? = nil) {
    self.id = id
    self.ts = ts
    self.kind = kind
    self.importID = importID
    self.appBundleID = appBundleID
    self.appName = appName
    self.title = title
    self.host = host
    self.textHash = textHash
  }

  /// Everything but the text.
  public init(_ o: ImportObservation) {
    self.init(id: o.id, ts: ImportWire.rfc3339(o.ts), kind: o.kind.rawValue, importID: o.importID,
              appBundleID: o.appBundleID, appName: o.appName, title: o.title, host: o.host, textHash: o.textHash)
  }

  enum CodingKeys: String, CodingKey {
    case id, ts, kind, title, host
    case importID = "import_id"
    case appBundleID = "app_bundle_id"
    case appName = "app_name"
    case textHash = "text_hash"
  }
}

public final class LocalImportSink: ImportSink, @unchecked Sendable {
  /// A write to a space this sink did not open. (OffloadImport's `UnknownImportSpace` has no public initialiser.)
  public struct UnknownSpace: Error, Equatable {
    public let id: String
  }

  /// `OnDevice/imports`.
  public let folder: URL
  private let lock = NSLock()
  private var opened: Set<String> = []

  public init(folder: URL) { self.folder = folder }

  public func file(for id: String) -> URL { folder.appendingPathComponent("\(id).jsonl") }

  public func openImport(sourceKind: ImportSourceKind) async throws -> ImportSpace {
    let space = ImportSpace(id: UUID().uuidString.lowercased(), sourceKind: sourceKind)
    try create(space)
    return space
  }

  private func create(_ space: ImportSpace) throws {
    lock.lock()
    defer { lock.unlock() }
    try OnDeviceFiles.ensureFolder(folder)
    try OnDeviceFiles.writeProtected(Data(), to: file(for: space.id))
    opened.insert(space.id)
  }

  public func write(_ observations: [ImportObservation], to space: ImportSpace) throws {
    lock.lock()
    defer { lock.unlock() }
    guard opened.contains(space.id) else { throw UnknownSpace(id: space.id) }
    guard !observations.isEmpty else { return }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    var data = Data()
    for o in observations {
      data.append(try encoder.encode(StoredObservation(o)))
      data.append(0x0A)
    }
    let handle = try FileHandle(forWritingTo: file(for: space.id))
    defer { try? handle.close() }
    _ = try handle.seekToEnd()
    try handle.write(contentsOf: data)
  }

  /// "Remove imported data": the import's file is deleted.
  public func forget(_ space: ImportSpace) async throws {
    try remove(space)
  }

  private func remove(_ space: ImportSpace) throws {
    lock.lock()
    defer { lock.unlock() }
    let url = file(for: space.id)
    if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    opened.remove(space.id)
  }
}

/// Reads every import kept on this Mac back as insight events. Lines it cannot decode are skipped.
public struct LocalObservationStore: InsightEventReader {
  public let folder: URL

  public init(folder: URL) { self.folder = folder }

  /// The import ids with a file here, sorted.
  public func importIDs() -> [String] {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
    return names.filter { $0.hasSuffix(".jsonl") && !$0.hasPrefix(".") }.map { String($0.dropLast(6)) }.sorted()
  }

  /// Every stored line of one import.
  public func stored(importID: String) -> [StoredObservation] {
    let url = folder.appendingPathComponent("\(importID).jsonl")
    guard let data = try? Data(contentsOf: url) else { return [] }
    let decoder = JSONDecoder()
    var out: [StoredObservation] = []
    for line in data.split(separator: 0x0A) where !line.isEmpty {
      if let o = try? decoder.decode(StoredObservation.self, from: Data(line)) { out.append(o) }
    }
    return out
  }

  public func events(in interval: DateInterval) -> [InsightEvent] {
    var out: [InsightEvent] = []
    for id in importIDs() {
      for s in stored(importID: id) {
        guard let e = InsightEvent(stored: s), e.ts >= interval.start, e.ts < interval.end else { continue }
        out.append(e)
      }
    }
    return out
  }

  public func dayLabels(timeZone: TimeZone) -> [String] {
    var labels = Set<String>()
    for id in importIDs() {
      for s in stored(importID: id) {
        if let e = InsightEvent(stored: s) { labels.insert(LocalDays.label(e.ts, timeZone: timeZone)) }
      }
    }
    return labels.sorted()
  }
}
