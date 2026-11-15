// The two macOS permissions the Mac client needs, and where their current state comes from.
// m3-02-mac-capture-upload owns the real permission checker; it has not landed yet, so the interface is defined here
// and m3-02's checker conforms to it. See docs/ONBOARDING.md section 11 (lost permissions).
import ApplicationServices
import CoreGraphics

/// A macOS permission grant (not an entitlement; docs/DEPLOYMENT.md section 3.3).
enum Permission: String, CaseIterable, Sendable {
    case accessibility
    case screenRecording

    /// The name System Settings uses.
    var displayName: String {
        switch self {
        case .accessibility: "Accessibility"
        case .screenRecording: "Screen Recording"
        }
    }
}

/// Answers whether a permission is granted right now. Never prompts.
@MainActor
protocol PermissionSource {
    func isGranted(_ permission: Permission) -> Bool
}

/// Reads the live grants without prompting. Stands in until m3-02's permission checker replaces it.
@MainActor
final class SystemPermissionSource: PermissionSource {
    init() {}

    func isGranted(_ permission: Permission) -> Bool {
        switch permission {
        case .accessibility: AXIsProcessTrusted()
        case .screenRecording: CGPreflightScreenCaptureAccess()
        }
    }
}
