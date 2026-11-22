// m3-03's updater wiring for the SwiftUI app shell (m3-04). Before the rebase onto main (2026-11-22) it lived in
// OffloadMac.swift's placeholder AppKit delegate; every decision stays in Updates/ (UpdateFeedConfig,
// UpdateLifecycle, UpdaterController). docs/DEPLOYMENT.md section 4.
import Foundation

/// One line the updater adds to the menu bar item.
public struct UpdateMenuEntry: Hashable, Sendable {
  public enum Action: Hashable, Sendable {
    /// A line that only informs (shown disabled).
    case disabled
    /// "Check for Updates…".
    case checkForUpdates
  }

  public var title: String
  public var action: Action

  public init(title: String, action: Action) {
    self.title = title
    self.action = action
  }
}

/// The updater's menu lines, as the placeholder menu showed them: one "<permission> is off" line per permission
/// missing on the first launch after an update, then "Check for Updates…" when this build has a signed feed, else the
/// status line.
enum UpdateMenu {
  @MainActor
  static func entries(feed: UpdateFeedConfig, missingAfterUpdate: [Permission]) -> [UpdateMenuEntry] {
    var lines = missingAfterUpdate.map { UpdateMenuEntry(title: "\($0.displayName) is off", action: .disabled) }
    if feed.isEnabled {
      lines.append(UpdateMenuEntry(title: UpdaterController.checkForUpdatesTitle, action: .checkForUpdates))
    } else {
      lines.append(UpdateMenuEntry(title: feed.statusLine, action: .disabled))
    }
    return lines
  }
}

/// Starts the updater once per launch and runs the after-update permission check (UpdateLifecycle.didLaunch).
/// `capture` is the app's one CaptureRuntime (m3-14's composition root), so an update stops real capture first.
@MainActor
final class AppUpdates {
  let updater: UpdaterController
  let menu: [UpdateMenuEntry]
  private let lifecycle: UpdateLifecycle

  init(capture: any CaptureLifecycle) {
    let settings = UserDefaults.standard
    let lifecycle = UpdateLifecycle(
      capture: capture,
      permissions: SystemPermissionSource(),
      settings: settings
    )
    let updater = UpdaterController(info: Bundle.main.infoDictionary, lifecycle: lifecycle, settings: settings)
    let missing = lifecycle.didLaunch()
    self.lifecycle = lifecycle
    self.updater = updater
    self.menu = UpdateMenu.entries(feed: updater.feed, missingAfterUpdate: missing)
  }
}
