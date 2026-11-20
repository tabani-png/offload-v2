import Foundation

/// The line `Offload --version` prints (slice m3-09-mac-test-build): `Offload <version> (<build>) <commit> <bundle id>`
/// from the bundle's Info.plist, or `Offload dev` for a `swift build` binary without one. The installed-copy smoke
/// check (apps/mac/TestBuild/build-app.sh smoke) compares it exactly. Pure, so the M309 tests reach it; the app
/// target only prints it and exits.
public enum VersionLine {
  /// Nil when `--version` was not asked for. `arguments` includes the program path first, as `CommandLine.arguments`.
  public static func line(arguments: [String], info: [String: Any]?) -> String? {
    guard arguments.dropFirst().contains("--version") else { return nil }
    guard let info,
      let version = info["CFBundleShortVersionString"] as? String,
      let build = info["CFBundleVersion"] as? String,
      let id = info["CFBundleIdentifier"] as? String
    else { return "Offload dev" }
    let commit = info["OffloadCommit"] as? String ?? "unknown"
    return "Offload \(version) (\(build)) \(commit) \(id)"
  }
}
