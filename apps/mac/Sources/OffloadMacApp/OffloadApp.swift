import AppKit
import OffloadMac
import SwiftUI

// The Offload app: a menu bar item and one main window. All logic and views live in the OffloadMac library
// (tested there); this file only wires the live pieces.

@main
struct OffloadApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
  @StateObject private var app = AppModel.live()

  var body: some Scene {
    Window("Offload", id: "main") {
      MainWindowView(app: app)
    }
    .windowResizability(.contentMinSize)

    MenuBarExtra {
      MenuBarOpener(app: app)
    } label: {
      MenuBarLabel(app: app)
    }
  }
}

/// Opens the main window from the menu bar item.
struct MenuBarOpener: View {
  @ObservedObject var app: AppModel
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    MenuBarContent(app: app) {
      openWindow(id: "main")
      NSApp.activate()
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
