import Foundation
import Testing
import OffloadMac

// m3-09-mac-test-build (slices/m3-09-mac-test-build/SPEC.md): the `Offload --version` line the installed-copy smoke
// check compares (apps/mac/TestBuild/build-app.sh smoke). Pure: no bundle, no window, no TCC.

@Suite struct M309 {
  /// A function, not a stored `static let`: `[String: Any]` is not Sendable, so Swift 6 rejects it as shared state.
  static func bundled() -> [String: Any] {
    [
      "CFBundleShortVersionString": "0.1.0",
      "CFBundleVersion": "9",
      "CFBundleIdentifier": "ai.offload.mac.dev",
      "OffloadCommit": "0123456",
    ]
  }

  @Test("VERSION: a bundled build prints its version, build, commit and bundle id")
  func bundledLine() {
    let line = VersionLine.line(arguments: ["/Applications/Offload.app/Contents/MacOS/Offload", "--version"], info: M309.bundled())
    #expect(line == "Offload 0.1.0 (9) 0123456 ai.offload.mac.dev")
  }

  @Test("VERSION: a swift build binary without an Info.plist prints Offload dev")
  func devLine() {
    #expect(VersionLine.line(arguments: ["Offload", "--version"], info: nil) == "Offload dev")
    // Foundation gives a bare binary a few keys of its own, but never a version.
    #expect(VersionLine.line(arguments: ["Offload", "--version"], info: ["CFBundleIdentifier": "Offload"]) == "Offload dev")
  }

  @Test("VERSION: a bundle without OffloadCommit prints unknown for the commit")
  func unknownCommit() {
    var info = M309.bundled()
    info.removeValue(forKey: "OffloadCommit")
    #expect(VersionLine.line(arguments: ["Offload", "--version"], info: info) == "Offload 0.1.0 (9) unknown ai.offload.mac.dev")
  }

  @Test("VERSION: without --version the app starts as usual")
  func noFlag() {
    #expect(VersionLine.line(arguments: ["Offload"], info: M309.bundled()) == nil)
    #expect(VersionLine.line(arguments: ["Offload", "--onboarding"], info: M309.bundled()) == nil)
    // The program path is not an argument, even if it were called --version.
    #expect(VersionLine.line(arguments: ["--version"], info: M309.bundled()) == nil)
  }
}
