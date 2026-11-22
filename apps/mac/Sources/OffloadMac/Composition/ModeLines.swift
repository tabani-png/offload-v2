// What the menu bar item says about where data goes (slice m3-14-mac-app-integration, review 1 finding 3). The test
// build runs in Local mode and has no on-device text reading yet (m3-10), so it says both, instead of looking broken.
// GLOSSARY "Local mode". Copy: plain, no em dashes (docs/PRODUCT.md copy rules).
public enum ModeLines {
  public static let local = "Local mode: nothing leaves this Mac"
  public static let importNotReady = "Recordings import needs on-device text reading, not in this build yet"

  /// Local mode first, then the import line while no importer exists.
  public static func lines(backend: BackendMode, importReady: Bool) -> [String] {
    var out: [String] = []
    if !backend.allowsUploads { out.append(local) }
    if !importReady { out.append(importNotReady) }
    return out
  }
}
