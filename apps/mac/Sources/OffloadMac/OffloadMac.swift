// OffloadMac: thin Mac client. See docs/ARCHITECTURE.md#1-mac-client.
// The entry point of the `Offload` executable. `Offload --self-check` runs SelfCheck and exits without any UI;
// otherwise a minimal menu bar app starts. m3-02-mac-capture-upload replaces this file's placeholder UI; the updater
// wiring (m3-03) is the one `updater.menuItem()` line below.
import AppKit
import Foundation

/// TODO: not implemented. See docs/ARCHITECTURE.md#1-mac-client.
public enum OffloadMacTodo {
    public static let marker = "TODO: not implemented. See docs/ARCHITECTURE.md#1-mac-client"
}

@main
enum OffloadEntry {
    static func main() {
        if CommandLine.arguments.contains(SelfCheck.argument) {
            let code = MainActor.assumeIsolated {
                SelfCheck.run(
                    environment: ProcessInfo.processInfo.environment,
                    info: Bundle.main.infoDictionary,
                    permissions: FakePermissionSource(),
                    capture: CaptureNotStarted(),
                    write: { print($0) }
                )
            }
            exit(code)
        }
        MainActor.assumeIsolated {
            let app = NSApplication.shared
            let delegate = OffloadAppDelegate()
            app.delegate = delegate
            app.setActivationPolicy(.accessory)
            // NSApplication holds its delegate weakly.
            withExtendedLifetime(delegate) { app.run() }
        }
    }
}

/// Placeholder menu bar app until m3-02: a status item with the updater and Quit.
@MainActor
final class OffloadAppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var lifecycle: UpdateLifecycle?
    private var updater: UpdaterController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let settings = UserDefaults.standard
        let lifecycle = UpdateLifecycle(
            capture: CaptureNotStarted(),
            permissions: SystemPermissionSource(),
            settings: settings
        )
        let updater = UpdaterController(info: Bundle.main.infoDictionary, lifecycle: lifecycle, settings: settings)
        let missing = lifecycle.didLaunch()

        let menu = NSMenu()
        // After an update, a missing permission is named here until m3-04's repair banner exists.
        for permission in missing {
            let item = NSMenuItem(title: "\(permission.displayName) is off", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        menu.addItem(updater.menuItem())
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit Offload", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "Offload"
        statusItem.menu = menu

        self.statusItem = statusItem
        self.lifecycle = lifecycle
        self.updater = updater
    }
}
