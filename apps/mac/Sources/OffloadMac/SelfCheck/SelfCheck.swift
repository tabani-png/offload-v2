// `Offload --self-check`: the installed-copy smoke test in the CI mac job (docs/DEPLOYMENT.md section 6). Runs in an
// empty environment with a temp HOME. Starts no UI and no Sparkle updater, touches no network, writes nothing to disk
// (settings live in memory), and never prints an environment value.
import Foundation

/// Checks that the built app starts and runs its update lifecycle against a fake permission source.
@MainActor
enum SelfCheck {
    static let argument = "--self-check"

    /// Runs every step and returns the process exit code: 0 when all pass, 1 on the first failure.
    static func run(
        environment: [String: String],
        info: [String: Any]?,
        permissions: any PermissionSource,
        capture: any CaptureLifecycle,
        write: (String) -> Void
    ) -> Int32 {
        if let reason = homeProblem(environment) {
            write("self-check: failed (\(reason))")
            return 1
        }
        write("self-check: home folder ok")

        let lifecycle = UpdateLifecycle(capture: capture, permissions: permissions, settings: MemorySettingsStore())
        // No real capture exists until m3-02; CaptureNotStarted makes this a no-op.
        capture.start()
        write("self-check: capture started")

        lifecycle.willInstallUpdate()
        write("self-check: capture stopped for an update")

        let missing = lifecycle.didLaunch()
        guard missing.isEmpty else {
            let names = missing.map(\.displayName).joined(separator: ", ")
            write("self-check: failed (missing after relaunch: \(names))")
            return 1
        }
        write("self-check: both permissions checked after relaunch")

        write("self-check: \(UpdateFeedConfig(info: info ?? [:]).statusLine)")
        write("self-check: ok")
        return 0
    }

    /// Why HOME is unusable, or nil. Names the variable, never its value.
    private static func homeProblem(_ environment: [String: String]) -> String? {
        guard let home = environment["HOME"], !home.isEmpty else { return "HOME is not set" }
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: home, isDirectory: &isFolder), isFolder.boolValue else {
            return "HOME is not a folder"
        }
        guard FileManager.default.isWritableFile(atPath: home) else { return "HOME is not writable" }
        return nil
    }
}
