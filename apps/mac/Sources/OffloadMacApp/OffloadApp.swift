import AppKit
import OffloadMac
import SwiftUI

// The Offload app: a menu bar item and one main window. All logic and views live in the OffloadMac library
// (tested there); this file only wires the live pieces.

/// Entry point. `Offload --version` answers before any window, menu bar item or permission check exists, so the
/// installed-copy smoke check (apps/mac/TestBuild/build-app.sh smoke, slice m3-09) can run it with an empty
/// environment. Everything else starts the SwiftUI app.
@main
enum OffloadMain {
  @MainActor
  static func main() {
    if let line = VersionLine.line(arguments: CommandLine.arguments, info: Bundle.main.infoDictionary) {
      FileHandle.standardOutput.write(Data((line + "\n").utf8))
      exit(0)
    }
    OffloadApp.main()
  }
}

struct OffloadApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
  @StateObject private var app = AppModel.live()

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
