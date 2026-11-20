import Foundation
import OffloadImport

/// The person's Never watch list (m3-04's `ExclusionSource`, built-ins and their own entries) as the importer's
/// rules. The importer reads it before every file, so an entry added during an import applies from the next file.
/// `appNames` gives every name an installed app is shown by (localized too). The app looks them up when each import
/// starts (`RecordingsImportModel.startImport`, through `LiveAppNames.resolver(for:)`), so a recorded app that is in
/// no built-in table, or a Mac in another language, is still matched by the name its menu bar shows. With a lookup,
/// the built-in password and banking apps are matched by their looked-up names as well.
public struct NeverWatchImportExclusions: ImportExclusionSource {
  public let source: any ExclusionSource
  public let appNames: (@Sendable (String) -> [String])?

  public init(source: any ExclusionSource, appName: (@Sendable (String) -> String?)? = nil) {
    self.source = source
    if let lookup = appName {
      self.appNames = { @Sendable id in lookup(id).map { [$0] } ?? [] }
    } else {
      self.appNames = nil
    }
  }

  public init(source: any ExclusionSource, appNames: @escaping @Sendable (String) -> [String]) {
    self.source = source
    self.appNames = appNames
  }

  public func currentRules() -> [ImportExclusionRule] {
    var rules = source.currentExclusions().map { e -> ImportExclusionRule in
      switch e.kind {
      case .bundleID: return ImportExclusionRule(kind: .bundleID, value: e.value, appNames: appNames?(e.value) ?? [])
      case .host: return ImportExclusionRule(kind: .host, value: e.value)
      case .titleContains: return ImportExclusionRule(kind: .titleContains, value: e.value)
      }
    }
    guard let appNames else { return rules }
    let listed = Set(rules.filter { $0.kind == .bundleID }.map { $0.value.lowercased() })
    for id in ImportExclusions.builtInBundleIDs where !listed.contains(id) {
      let names = appNames(id)
      if !names.isEmpty { rules.append(ImportExclusionRule(kind: .bundleID, value: id, appNames: names)) }
    }
    return rules
  }
}
