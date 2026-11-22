// The recordings import with the real pieces (slice m3-14-mac-app-integration; W1-D audit gap 1): PR #13's masker
// masks recordings text the same way it masks live text, and when this Mac sends, the uploader is the import's only
// way out. On-device OCR (the TextRecognizer) and the local analysis store are m3-10's; until it plugs them in
// (CompositionSeams) there is no importer and Import says it needs on-device text reading.
import Foundation
import OffloadContracts
import OffloadImport
import OffloadMasker

/// m3-05's `ImportTextMasker` over PR #13's `TextMasker`. The masker (its pseudonym key) is loaded on first use; when it
/// cannot be loaded, no text is written at all (fail closed).
public final class ImportMaskerAdapter: ImportTextMasker, @unchecked Sendable {
  private let lock = NSLock()
  private let load: @Sendable () throws -> TextMasker
  private var loaded: TextMasker?

  public init(masker: TextMasker) {
    load = { masker }
    loaded = masker
  }

  public init(load: @escaping @Sendable () throws -> TextMasker) { self.load = load }

  public func mask(_ text: String) -> String {
    guard let masker = current() else { return "" }
    return masker.mask(text).text
  }

  private func current() -> TextMasker? {
    lock.withLock {
      if let loaded { return loaded }
      guard let made = try? load() else { return nil }
      loaded = made
      return made
    }
  }
}

public enum ImportComposition {
  /// The importer, or nil while there is no on-device text reading or no sink (Import then reads nothing). The
  /// person's Never watch list is read before every file.
  public static func importer(recognizer: (any TextRecognizer)?, masker: any ImportTextMasker, sink: (any ImportSink)?,
                              ledger: any RecordingLedger, neverWatch: any ExclusionSource,
                              protected: [URL]) -> RecordingImporter? {
    guard let recognizer, let sink else { return nil }
    return RecordingImporter(recognizer: recognizer, masker: masker, exclusions: NeverWatchImportExclusions(source: neverWatch),
                             sink: sink, ledger: ledger, protected: protected)
  }
}

/// What the import needs from the uploader (UploadRuntime in the app; a fake in tests).
public protocol ImportUploadQueue: Sendable {
  /// `POST /v1/imports` with `{ source_kind }`; the `import_id`.
  func openImport(sourceKind: String) async throws -> String
  /// Synchronous and durable: checked (import objects only, detectors again) and sealed on this Mac before it
  /// returns; the uploader's next flush batches them. Throws when anything is refused, so nothing is half kept.
  func stageImport(_ objects: [Observation]) throws
  /// `POST /v1/me/forget` with `{ scope: "import", import_id }`.
  func forgetImport(id: String) async throws
}

/// Why the sink refused objects before anything was kept.
public struct ImportUploadRefusal: Error, Equatable, Sendable {
  public let reason: String
}

/// m3-05's `ImportSink` through the uploader: it makes no request of its own. Every object is converted through the
/// closed `Observation` schema and must be `source = "import"` of the space it is written to. `write` returns only
/// after the objects are staged on this Mac, so a recording the importer records as read is never lost; when staging
/// fails, `write` throws and the importer leaves the file for the next import (review 1, finding 2).
public final class UploaderImportSink: ImportSink, @unchecked Sendable {
  private let queue: any ImportUploadQueue
  private let lock = NSLock()
  private var open: Set<String> = []

  public init(queue: any ImportUploadQueue) { self.queue = queue }

  public func openImport(sourceKind: ImportSourceKind) async throws -> ImportSpace {
    let id = try await queue.openImport(sourceKind: sourceKind.rawValue)
    guard !id.isEmpty else { throw ImportUploadRefusal(reason: "no import_id") }
    lock.withLock { _ = open.insert(id) }
    return ImportSpace(id: id, sourceKind: sourceKind)
  }

  public func write(_ observations: [ImportObservation], to space: ImportSpace) throws {
    guard lock.withLock({ open.contains(space.id) }) else {
      throw ImportUploadRefusal(reason: "an import space this sink did not open")
    }
    let objects = try observations.map { try Self.observation($0, in: space) }
    guard !objects.isEmpty else { return }
    try queue.stageImport(objects)
  }

  public func forget(_ space: ImportSpace) async throws {
    try await queue.forgetImport(id: space.id)
    lock.withLock { _ = open.remove(space.id) }
  }

  static func observation(_ o: ImportObservation, in space: ImportSpace) throws -> Observation {
    guard o.importID == space.id else { throw ImportUploadRefusal(reason: "an object of another import space") }
    let decoded: Observation
    do {
      decoded = try JSONDecoder().decode(Observation.self, from: JSONEncoder().encode(o))
    } catch {
      throw ImportUploadRefusal(reason: "not a closed-schema observation")
    }
    guard source(of: decoded) == .import, importID(of: decoded) == space.id else {
      throw ImportUploadRefusal(reason: "not an import object of this space")
    }
    return decoded
  }

  public static func source(of o: Observation) -> ObservationSource? { o.originSource }
  public static func importID(of o: Observation) -> String? { o.originImportID }
}
