import Foundation

// Where an import's masked observations go. The real sink opens the import space with `POST /v1/imports`, hands the
// observations to the uploader (m3-02), which sends them with `source = "import"` and the `import_id`, and forgets an
// import with `POST /v1/me/forget` scope `import`. The server half lands after m1-02; this slice ships the in-memory
// fake only.

public protocol ImportSink: Sendable {
  /// `POST /v1/imports` with `{ source_kind }`.
  func openImport(sourceKind: ImportSourceKind) async throws -> ImportSpace
  /// Masked observations of one import space, queued for upload. Only observations: no pixels, no file names.
  func write(_ observations: [ImportObservation], to space: ImportSpace) throws
  /// `POST /v1/me/forget` with `{ scope: "import", import_id }`: the import space is wiped as a unit.
  func forget(_ space: ImportSpace) async throws
}

public struct UnknownImportSpace: Error, Equatable {
  public let id: String
}

/// Keeps import spaces and their observations in memory. The only sink until the server half exists.
public final class InMemoryImportSink: ImportSink, @unchecked Sendable {
  private let lock = NSLock()
  private var opened: [ImportSpace] = []
  private var written: [String: [ImportObservation]] = [:]
  private var forgottenIDs: [String] = []

  public init() {}

  public func openImport(sourceKind: ImportSourceKind) async throws -> ImportSpace {
    let space = ImportSpace(id: UUID().uuidString.lowercased(), sourceKind: sourceKind)
    locked { opened.append(space) }
    return space
  }

  public func write(_ observations: [ImportObservation], to space: ImportSpace) throws {
    try locked {
      guard opened.contains(space) else { throw UnknownImportSpace(id: space.id) }
      written[space.id, default: []].append(contentsOf: observations)
    }
  }

  public func forget(_ space: ImportSpace) async throws {
    locked {
      written[space.id] = nil
      opened.removeAll { $0 == space }
      forgottenIDs.append(space.id)
    }
  }

  public var spaces: [ImportSpace] { locked { opened } }
  public var forgotten: [String] { locked { forgottenIDs } }
  public func observations(in id: String) -> [ImportObservation] { locked { written[id] ?? [] } }

  private func locked<T>(_ body: () throws -> T) rethrows -> T {
    lock.lock()
    defer { lock.unlock() }
    return try body()
  }
}
