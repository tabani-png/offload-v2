// What the updater needs from capture. The real conformer is m3-02's CaptureRuntime (Composition/, m3-14), which the
// composition root hands to the updater; `--self-check` keeps CaptureNotStarted (no Keychain, no store in CI).

/// Starts capture and stops it cleanly before an update installs.
@MainActor
protocol CaptureLifecycle {
    /// Starts capture with the permissions that are granted.
    func start()
    /// Stops capture and pauses uploads (the app's UpdatePreparation, m3-14). Both queues are on disk, so nothing is
    /// lost; the next launch starts them again. Called before Sparkle installs an update.
    func prepareForUpdate()
}

/// For `Offload --self-check`: nothing to start, flush or stop.
@MainActor
final class CaptureNotStarted: CaptureLifecycle {
    init() {}
    func start() {}
    func prepareForUpdate() {}
}
