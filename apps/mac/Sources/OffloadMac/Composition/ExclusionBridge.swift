// Never watch reaches the running observer (slice m3-14-mac-app-integration; W1-D audit gap 5). The person's list
// lives in m3-04's NeverWatchStore; PR #13's observer re-reads `StoreLayout.exclusionsFile` every 2 s
// (ExclusionReloader) on top of its built-in list. The capture runtime writes the store's entries to that file before
// every observer tick, so an entry added on screen 9, in Settings or from the menu bar stops being watched within one
// check. The recordings import reads the same store directly (NeverWatchImportExclusions, m3-05).
import Foundation
import OffloadObserver

public enum ExclusionBridge {
  /// The same three kinds on both sides (DATA_MODEL `exclusions`).
  public static func rules(from exclusions: [Exclusion]) -> [ExclusionRule] {
    exclusions.map { e -> ExclusionRule in
      switch e.kind {
      case .bundleID: return ExclusionRule(kind: .bundleID, value: e.value)
      case .host: return ExclusionRule(kind: .host, value: e.value)
      case .titleContains: return ExclusionRule(kind: .titleContains, value: e.value)
      }
    }
  }
}

/// Keeps the observer's exclusions file equal to the Never watch list. Writes only when the list changed (or the file
/// is missing), atomically, so the reloader never reads half a file.
@MainActor public final class ExclusionsFile {
  public let file: URL
  private let source: any ExclusionSource
  private var written: [ExclusionRule]?

  public init(file: URL, source: any ExclusionSource) {
    self.file = file
    self.source = source
  }

  /// True when the file was written.
  @discardableResult
  public func sync() throws -> Bool {
    let rules = ExclusionBridge.rules(from: source.currentExclusions())
    if let written, written == rules, FileManager.default.fileExists(atPath: file.path) { return false }
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    try encoder.encode(rules).write(to: file, options: .atomic)
    written = rules
    return true
  }

  /// The rules in a file this type wrote.
  public nonisolated static func read(_ file: URL) throws -> [ExclusionRule] {
    try JSONDecoder().decode([ExclusionRule].self, from: Data(contentsOf: file))
  }
}
