import AppKit
import SwiftUI

// The Offload app: a menu bar item and one main window. All logic and views live in the other folders of this module
// (tested there); this file only shows what the one composition root built (`AppComposition.live()`, m3-14). The
// process entry point is `OffloadEntry` in OffloadMac.swift: `EntryCommand` answers `--self-check` (m3-03) and
// `--version` (m3-09) before any window, menu bar item or permission check exists, and otherwise starts this app.

struct OffloadApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
  @StateObject private var app: AppModel
  /// Sparkle (m3-03), started by the composition root before any scene, as Sparkle's own SwiftUI setup does.
  private let updates: AppUpdates?

  init() {
    let root = AppComposition.live()
    _app = StateObject(wrappedValue: root.app)
    updates = root.updates
  }

  var body: some Scene {
    Window("Offload", id: "main") {
      MainWindowView(app: app)
    }
    .windowResizability(.contentMinSize)

    // Settings, Recordings (m3-05). A window, not a `Settings` scene, so the menu bar item can open it in front.
    Window(RecordingsCopy.settingsTitle, id: "settings") {
      OffloadSettingsView(app: app)
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
  let updates: AppUpdates?
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    MenuBarContent(
      app: app,
      openWindow: {
        openWindow(id: "main")
        NSApp.activate()
      },
      updates: updates?.menu ?? [],
      checkForUpdates: { updates?.updater.checkForUpdates(nil) }
    )
    // Hidden in Local mode and before "Start sending" (ONBOARDING section 8).
    if app.recordings?.isOffered == true {
      Button(RecordingsCopy.menuItem) {
        openWindow(id: "settings")
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
