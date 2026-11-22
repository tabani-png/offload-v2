// What happens around an update, without Sparkle: stop capture before install, check permissions after relaunch.
// docs/DEPLOYMENT.md section 4 (Behaviour, Permissions across updates) and docs/ONBOARDING.md section 11.4.

/// Prepares capture for an update and re-checks both permissions on the first launch after it.
@MainActor
final class UpdateLifecycle {
    /// Settings key set just before an update installs and cleared on the next launch.
    static let pendingRelaunchCheckKey = "pendingRelaunchCheck"

    private let capture: any CaptureLifecycle
    private let permissions: any PermissionSource
    private let settings: any SettingsStore

    init(capture: any CaptureLifecycle, permissions: any PermissionSource, settings: any SettingsStore) {
        self.capture = capture
        self.permissions = permissions
        self.settings = settings
    }

    /// Called from Sparkle's will-install delegate: flush the upload queue and stop capture, then remember to check
    /// permissions on the next launch.
    func willInstallUpdate() {
        capture.prepareForUpdate()
        settings.set(true, forKey: Self.pendingRelaunchCheckKey)
    }

    /// Called once at launch. After an update, checks both permissions and returns the missing ones (for the quiet
    /// repair banner); on any other launch checks nothing and returns [].
    func didLaunch() -> [Permission] {
        guard settings.bool(forKey: Self.pendingRelaunchCheckKey) else { return [] }
        settings.removeObject(forKey: Self.pendingRelaunchCheckKey)
        return Permission.allCases.filter { !permissions.isGranted($0) }
    }
}
