import AppKit
import SwiftUI

// The Offload app: a menu bar item and one main window. All logic and views live in the other folders of this module
// (tested there); this file only wires the live pieces. The process entry point is `OffloadEntry` in OffloadMac.swift
// (m3-03): it answers `--self-check` and `--version` (m3-09) before any window, menu bar item or permission check
// exists, and otherwise starts this app.

struct OffloadApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
  @StateObject private var app = AppModel.live()
  /// Sparkle (m3-03) starts here, before any scene, as Sparkle's own SwiftUI setup does.
  private let updates = AppUpdates()

  var body: some Scene {
    Window("Offload", id: "main") {
      // m3-10: the sidebar shell once setup is done; onboarding, move and Start fresh are MainWindowView as before.
      AppWindowView(app: app)
    }
    .windowResizability(.contentMinSize)

    // Settings, Recordings (m3-05). A window, not a `Settings` scene, so the menu bar item can open it in front.
    Window(RecordingsCopy.settingsTitle, id: "settings") {
      // m3-10: a window macOS restores shows a button until the person asks, so no folder is read at launch.
      SettingsWindowView(app: app)
    }
    .windowResizability(.contentMinSize)
    // Not listed in the Window menu: it opens only from the menu bar item, which shows it only while sending. A
    // window macOS restores at launch reads no folder while the import is not offered (RecordingsImportModel.refresh).
    .commandsRemoved()

    MenuBarExtra {
      MenuBarOpener(app: app, updates: updates)
    } label: {
      MenuBarLabel(app: app)
    }
  }
}

/// Opens the main window from the menu bar item.
struct MenuBarOpener: View {
  @ObservedObject var app: AppModel
  let updates: AppUpdates
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    MenuBarContent(
      app: app,
      openWindow: {
        openWindow(id: "main")
        NSApp.activate()
      },
      updates: updates.menu,
      checkForUpdates: { updates.updater.checkForUpdates(nil) }
    )
    // Offered in Local mode (kept on this Mac) and in the cloud while sending (ONBOARDING section 8, m3-10).
    if app.recordings?.isOffered == true {
      Button(RecordingsCopy.menuItem) {
        if app.route == .today {
          app.navigation.selection = .recordings
          openWindow(id: "main")
        } else {
          app.navigation.requestSettings()
          openWindow(id: "settings")
        }
        NSApp.activate()
      }
    }
  }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
  func applicationDidFinishLaunching(_ notification: Notification) {
    // A `swift build` binary has no Info.plist; make it a regular app with a Dock icon and a window.
    NSApp.setActivationPolicy(.regular)
    NSApp.activate()
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
