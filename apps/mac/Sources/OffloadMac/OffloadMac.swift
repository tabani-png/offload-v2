// OffloadMac: thin Mac client. See docs/ARCHITECTURE.md#1-mac-client.
// The one entry point of the `Offload` executable (m3-14-mac-app-integration: one `@main`, one composition root).
// `EntryCommand` decides: `Offload --self-check` runs SelfCheck and exits without any UI (m3-03); `Offload --version`
// prints VersionLine and exits (m3-09, the test build's smoke check); otherwise the SwiftUI app starts
// (App/OffloadApp.swift), which builds everything once through `AppComposition.live()`.
import AppKit
import Foundation
import SwiftUI

@main
enum OffloadEntry {
    static func main() {
        switch EntryCommand.decide(arguments: CommandLine.arguments, info: Bundle.main.infoDictionary) {
        case .selfCheck:
            let code = MainActor.assumeIsolated {
                SelfCheck.run(
                    environment: ProcessInfo.processInfo.environment,
                    info: Bundle.main.infoDictionary,
                    permissions: FakePermissionSource(),
                    // The smoke check runs under `env -i` with a temp HOME: no Keychain, no store, no live capture.
                    capture: CaptureNotStarted(),
                    write: { print($0) }
                )
            }
            exit(code)
        case .version(let line):
            FileHandle.standardOutput.write(Data((line + "\n").utf8))
            exit(0)
        case .app:
            MainActor.assumeIsolated {
                OffloadApp.main()
            }
        }
    }
}
