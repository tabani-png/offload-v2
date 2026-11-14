// Sparkle 2 wiring (docs/DEPLOYMENT.md section 4). All decisions live in UpdateFeedConfig, UpdateChannels and
// UpdateLifecycle; this file only forwards to them, so the tests never need a running updater.
import AppKit
import Sparkle

/// Owns Sparkle's standard updater when the build has a signed feed, and the "Check for Updates…" menu item.
@MainActor
final class UpdaterController: NSObject {
    static let checkForUpdatesTitle = "Check for Updates…"
    /// Daily check.
    static let checkInterval: TimeInterval = 86_400

    let feed: UpdateFeedConfig
    /// Sparkle holds its delegate weakly, so this keeps it alive.
    private let delegate: UpdaterDelegate?
    private let controller: SPUStandardUpdaterController?

    /// Starts Sparkle only when `info` (the bundle's Info.plist) has a signed https feed; otherwise no updater runs.
    init(info: [String: Any]?, lifecycle: UpdateLifecycle, settings: any SettingsStore) {
        let feed = UpdateFeedConfig(info: info ?? [:])
        self.feed = feed
        if feed.isEnabled {
            let delegate = UpdaterDelegate(lifecycle: lifecycle, settings: settings)
            let controller = SPUStandardUpdaterController(
                startingUpdater: true,
                updaterDelegate: delegate,
                userDriverDelegate: nil
            )
            controller.updater.automaticallyChecksForUpdates = true
            controller.updater.updateCheckInterval = Self.checkInterval
            self.delegate = delegate
            self.controller = controller
        } else {
            self.delegate = nil
            self.controller = nil
        }
        super.init()
    }

    /// "Check for Updates…" when updates are on; otherwise a disabled item showing the status line.
    func menuItem() -> NSMenuItem {
        guard controller != nil else {
            let item = NSMenuItem(title: feed.statusLine, action: nil, keyEquivalent: "")
            item.isEnabled = false
            return item
        }
        let item = NSMenuItem(title: Self.checkForUpdatesTitle, action: #selector(checkForUpdates(_:)), keyEquivalent: "")
        item.target = self
        return item
    }

    /// The "Check for Updates…" action. Does nothing when updates are off.
    @objc func checkForUpdates(_ sender: Any?) {
        controller?.updater.checkForUpdates()
    }
}

/// Sparkle's updater delegate. SPUUpdaterDelegate is main-actor in Sparkle's headers and Sparkle calls it on the
/// main thread.
@MainActor
final class UpdaterDelegate: NSObject, SPUUpdaterDelegate {
    private let lifecycle: UpdateLifecycle
    private let settings: any SettingsStore

    init(lifecycle: UpdateLifecycle, settings: any SettingsStore) {
        self.lifecycle = lifecycle
        self.settings = settings
        super.init()
    }

    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        UpdateChannels.allowedChannels(settings: settings)
    }

    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        lifecycle.willInstallUpdate()
    }
}
