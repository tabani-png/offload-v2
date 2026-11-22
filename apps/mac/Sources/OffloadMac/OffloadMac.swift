// OffloadMac: thin Mac client. See docs/ARCHITECTURE.md#1-mac-client.
// The entry point of the `Offload` executable. `Offload --self-check` runs SelfCheck and exits without any UI;
// `Offload --version` prints VersionLine and exits (m3-09, the test build's smoke check); otherwise the SwiftUI app
// starts (App/OffloadApp.swift, m3-04). The updater wiring (m3-03) moved with the placeholder menu into
// App/AppUpdates.swift when this branch was rebased onto main (2026-11-22).
import AppKit
import Foundation
import SwiftUI

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
        if let line = VersionLine.line(arguments: CommandLine.arguments, info: Bundle.main.infoDictionary) {
            FileHandle.standardOutput.write(Data((line + "\n").utf8))
            exit(0)
        }
        MainActor.assumeIsolated {
            OffloadApp.main()
        }
    }
}
