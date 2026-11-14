import Foundation

/// Every call that touches TCC or System Settings, behind one protocol so tests use a fake and never prompt.
/// Input Monitoring has no method here on purpose: setup never asks for it.
@MainActor
public protocol PermissionProbe: AnyObject {
  /// `AXIsProcessTrusted()`.
  func isAccessibilityTrusted() -> Bool
  /// `CGPreflightScreenCaptureAccess()`.
  func screenCapturePreflight() -> Bool
  /// `AXIsProcessTrustedWithOptions` with the prompt option, so Offload appears in the Accessibility list.
  func promptAccessibility()
  /// `CGRequestScreenCaptureAccess()`: the system prompt, once per launch.
  func requestScreenCapture()
  func openSettings(_ url: URL)
  func revealAppInFinder()
  var macOSMajor: Int { get }
}
