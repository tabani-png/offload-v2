// The live glue for focus, idle, power, permissions and pause. Compile-checked on CI's mac job; the observer logic
// they feed is tested with fakes (Tests/OffloadMacTests/M302). Runs on the main actor.
import AppKit
import ApplicationServices
import Carbon.HIToolbox
import CoreGraphics
import Foundation
import IOKit.ps

/// One Accessibility attribute, or nil when it is not there or access is denied.
func axAttribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
    return value
}

/// NSWorkspace for the frontmost app, Accessibility for the window title and a browser's URL.
@MainActor public final class LiveWorkspace: WorkspaceSource {
    private static let browsers: Set<String> = [
        "com.apple.Safari", "com.google.Chrome", "com.google.Chrome.canary", "com.brave.Browser", "com.microsoft.edgemac",
        "company.thebrowser.Browser", "org.mozilla.firefox", "com.vivaldi.Vivaldi", "com.operasoftware.Opera",
    ]

    public init() {}

    public func frontmost() -> FocusSnapshot? {
        guard let app = NSWorkspace.shared.frontmostApplication, let bundleID = app.bundleIdentifier else { return nil }
        let name = app.localizedName ?? bundleID
        var title = ""
        var url: String?
        if AXIsProcessTrusted() {
            let element = AXUIElementCreateApplication(app.processIdentifier)
            if let window = axAttribute(element, kAXFocusedWindowAttribute) {
                let w = window as! AXUIElement  // swiftlint:disable:this force_cast
                title = (axAttribute(w, kAXTitleAttribute) as? String) ?? ""
                if Self.browsers.contains(bundleID) { url = Self.browserURL(window: w) }
            }
        }
        return FocusSnapshot(bundleID: bundleID, appName: name, windowTitle: title, url: url, secureInputActive: IsSecureEventInputEnabled(), isPrivateBrowsing: false)
    }

    /// `AXDocument` of the window, else the `AXURL` of the first web area within a few levels.
    private static func browserURL(window: AXUIElement) -> String? {
        if let doc = axAttribute(window, kAXDocumentAttribute) as? String, doc.contains("://") { return doc }
        var queue: [(AXUIElement, Int)] = [(window, 0)]
        var seen = 0
        while !queue.isEmpty, seen < 300 {
            let (node, depth) = queue.removeFirst()
            seen += 1
            if (axAttribute(node, kAXRoleAttribute) as? String) == "AXWebArea", let url = axAttribute(node, kAXURLAttribute) as? URL { return url.absoluteString }
            guard depth < 8, let kids = axAttribute(node, kAXChildrenAttribute) as? [AXUIElement] else { continue }
            for kid in kids { queue.append((kid, depth + 1)) }
        }
        return nil
    }
}

/// CGEventSource: no permission needed.
@MainActor public final class LiveIdle: IdleSource {
    public init() {}

    public func secondsSinceLastInput() -> TimeInterval {
        guard let any = CGEventType(rawValue: ~0) else { return 0 }
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: any)
    }
}

/// IOKit power sources.
@MainActor public final class LivePower: PowerSource {
    public init() {}

    public var batteryFraction: Double? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in list {
            guard let d = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  (d[kIOPSPowerSourceStateKey] as? String) == kIOPSBatteryPowerValue,
                  let now = d[kIOPSCurrentCapacityKey] as? Double, let max = d[kIOPSMaxCapacityKey] as? Double, max > 0 else { continue }
            return now / max
        }
        return nil
    }
}

@MainActor public final class LivePermissions: PermissionSource {
    public init() {}

    public func current() -> PermissionState {
        PermissionState(screenRecording: CGPreflightScreenCaptureAccess(), accessibility: AXIsProcessTrusted())
    }
}

/// Screen lock, sleep and fast user switching pause capture; the user can pause too (`userPaused`).
@MainActor public final class LivePauseSource: PauseSource {
    public var userPaused = false
    private var locked = false
    private var asleep = false
    private var switchedAway = false
    private var tokens: [any NSObjectProtocol] = []

    public init() {
        let dist = DistributedNotificationCenter.default()
        let ws = NSWorkspace.shared.notificationCenter
        tokens.append(dist.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.locked = true }
        })
        tokens.append(dist.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.locked = false }
        })
        tokens.append(ws.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.asleep = true }
        })
        tokens.append(ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.asleep = false }
        })
        tokens.append(ws.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.switchedAway = true }
        })
        tokens.append(ws.addObserver(forName: NSWorkspace.sessionDidBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.switchedAway = false }
        })
    }

    public var current: PauseReason? {
        if asleep { return .sleep }
        if locked || switchedAway { return .lock }
        return userPaused ? .user : nil
    }
}
