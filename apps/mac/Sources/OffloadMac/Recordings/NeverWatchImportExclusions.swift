import Foundation
import OffloadImport

/// The person's Never watch list (m3-04's `ExclusionSource`, built-ins and their own entries) as the importer's
/// rules. The importer reads it before every file, so an entry added during an import applies from the next file.
/// `appName` resolves a bundle id to the app's display name (in the app: `LiveAppNames.displayName`), so a recorded
/// app that is in no built-in table is still matched by the name its menu bar shows.
public struct NeverWatchImportExclusions: ImportExclusionSource {
  public let source: any ExclusionSource
  public let appName: (@Sendable (String) -> String?)?

  public init(source: any ExclusionSource, appName: (@Sendable (String) -> String?)? = nil) {
    self.source = source
    self.appName = appName
  }

  public func currentRules() -> [ImportExclusionRule] {
    source.currentExclusions().map { e in
      switch e.kind {
      case .bundleID: return ImportExclusionRule(kind: .bundleID, value: e.value, appName: appName?(e.value))
      case .host: return ImportExclusionRule(kind: .host, value: e.value)
      case .titleContains: return ImportExclusionRule(kind: .titleContains, value: e.value)
      }
    }
  }
}
