// What the one `Offload` executable runs (slice m3-14-mac-app-integration). OffloadMac.swift holds the only `@main`;
// it asks this, before any window, menu bar item, Keychain read or file write exists.
import Foundation

public enum EntryCommand: Equatable, Sendable {
  /// `Offload --self-check` (m3-03): the installed-copy smoke check. No UI, no Sparkle, capture not started.
  case selfCheck
  /// `Offload --version` (m3-09): print the line and exit.
  case version(String)
  /// The SwiftUI app, built once by `AppComposition.live()`.
  case app

  /// SelfCheck.argument, readable from the nonisolated entry point (SelfCheck is main-actor isolated).
  public static let selfCheckFlag = "--self-check"

  /// `arguments` includes the program path first, as `CommandLine.arguments`. `--self-check` wins over `--version`.
  public static func decide(arguments: [String], info: [String: Any]?) -> EntryCommand {
    if arguments.dropFirst().contains(selfCheckFlag) { return .selfCheck }
    if let line = VersionLine.line(arguments: arguments, info: info) { return .version(line) }
    return .app
  }
}
