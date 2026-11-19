import Foundation
import OffloadImport

/// The person's Never watch list (m3-04's `ExclusionSource`, built-ins and their own entries) as the importer's
/// rules. The importer reads it before every file, so an entry added during an import applies from the next file.
public struct NeverWatchImportExclusions: ImportExclusionSource {
  public let source: any ExclusionSource

  public init(source: any ExclusionSource) { self.source = source }

  public func currentRules() -> [ImportExclusionRule] {
    source.currentExclusions().map { e in
      switch e.kind {
      case .bundleID: return ImportExclusionRule(kind: .bundleID, value: e.value)
      case .host: return ImportExclusionRule(kind: .host, value: e.value)
      case .titleContains: return ImportExclusionRule(kind: .titleContains, value: e.value)
      }
    }
  }
}
