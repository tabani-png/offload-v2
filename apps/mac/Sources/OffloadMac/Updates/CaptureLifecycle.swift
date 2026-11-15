// What the updater needs from capture. m3-02-mac-capture-upload provides the real conformer.

/// Starts capture and stops it cleanly before an update installs.
@MainActor
protocol CaptureLifecycle {
    /// Starts capture with the permissions that are granted.
    func start()
    /// Flushes the upload queue and stops capture cleanly. Called before Sparkle installs an update.
    func prepareForUpdate()
}

/// Placeholder until m3-02: no capture exists yet, so there is nothing to start, flush or stop.
@MainActor
final class CaptureNotStarted: CaptureLifecycle {
    init() {}
    func start() {}
    func prepareForUpdate() {}
}
