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
    if let line = VersionFlag.line(arguments: CommandLine.arguments, info: Bundle.main.infoDictionary) {
      FileHandle.standardOutput.write(Data((line + "\n").utf8))
      exit(0)
    }
    OffloadApp.main()
  }
}

/// `Offload <version> (<build>) <commit> <bundle id>` from the bundle's Info.plist, or `Offload dev` for a
/// `swift build` binary that has none. Nil when `--version` was not asked for.
enum VersionFlag {
  static func line(arguments: [String], info: [String: Any]?) -> String? {
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
