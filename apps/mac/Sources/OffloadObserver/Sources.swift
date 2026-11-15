// What the observer reads from the Mac, as protocols: the live glue (Live/) implements them with NSWorkspace,
// Accessibility, ScreenCaptureKit and IOKit; tests script them. Everything here runs on the main actor.
import Foundation

/// The frontmost app and its focused window at one poll. Raw values stay in memory: the observer masks the title and
/// reduces the URL before anything is written.
public struct FocusSnapshot: Equatable, Sendable {
    public var bundleID: String
    public var appName: String
    public var windowTitle: String
    /// Full URL when the frontmost app is a browser and the URL could be read; nil otherwise.
    public var url: String?
    /// Secure Event Input is on (a password field has focus). No text is read while it is on.
    public var secureInputActive: Bool
    /// The window is a private browsing window, as far as the glue knows.
    public var isPrivateBrowsing: Bool

    public init(bundleID: String, appName: String, windowTitle: String, url: String? = nil,
                secureInputActive: Bool = false, isPrivateBrowsing: Bool = false) {
        self.bundleID = bundleID
        self.appName = appName
        self.windowTitle = windowTitle
        self.url = url
        self.secureInputActive = secureInputActive
        self.isPrivateBrowsing = isPrivateBrowsing
    }
}

public struct PermissionState: Equatable, Sendable {
    /// Needed for the OCR fallback only.
    public var screenRecording: Bool
    /// Needed for titles, URLs and the text walk.
    public var accessibility: Bool

    public init(screenRecording: Bool, accessibility: Bool) {
        self.screenRecording = screenRecording
        self.accessibility = accessibility
    }
}

/// Why capture is paused. Screen lock and fast user switching both read as `lock`.
public enum PauseReason: Sendable, Equatable {
    case user
    case lock
    case sleep
}

@MainActor public protocol WorkspaceSource: AnyObject {
    /// Nil when nothing is frontmost or it cannot be read.
    func frontmost() -> FocusSnapshot?
}

/// Seconds since the last keyboard or mouse input (CGEventSource in the live glue; no permission needed).
@MainActor public protocol IdleSource: AnyObject {
    func secondsSinceLastInput() -> TimeInterval
}

@MainActor public protocol PowerSource: AnyObject {
    /// Battery charge from 0 to 1, or nil on mains power or a Mac without a battery.
    var batteryFraction: Double? { get }
}

@MainActor public protocol PermissionSource: AnyObject {
    func current() -> PermissionState
}

@MainActor public protocol PauseSource: AnyObject {
    var current: PauseReason? { get }
}

/// The text of the focused window from a bounded Accessibility walk. Nil when it cannot be read.
@MainActor public protocol AXTextSource: AnyObject {
    func axText(of snapshot: FocusSnapshot) -> AXWalkResult?
}

/// The OCR fallback (ScreenCaptureKit single window + Vision in the live glue). Called only for windows the exclusion
/// policy allows, with Screen Recording granted and not on a low battery.
@MainActor public protocol OCRSource: AnyObject {
    func ocrText(of snapshot: FocusSnapshot) async throws -> String?
}
