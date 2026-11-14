import AppKit
import ApplicationServices
import CoreGraphics

/// The real TCC calls. Constructed only by the app at launch; tests use a fake probe and never reach this type.
/// Ported from clicky leanring-buddy/WindowPositionManager.swift (MIT, see NOTICE).
@MainActor
public final class LivePermissionProbe: PermissionProbe {
  public init() {}

  public var macOSMajor: Int { ProcessInfo.processInfo.operatingSystemVersion.majorVersion }

  public func isAccessibilityTrusted() -> Bool { AXIsProcessTrusted() }

  public func screenCapturePreflight() -> Bool { CGPreflightScreenCaptureAccess() }

  public func promptAccessibility() {
    // The value of kAXTrustedCheckOptionPrompt, spelled out: the imported global is a mutable C variable, which
    // Swift 6 strict concurrency rejects.
    let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
    _ = AXIsProcessTrustedWithOptions(options)
  }

  public func requestScreenCapture() {
    _ = CGRequestScreenCaptureAccess()
  }

  public func openSettings(_ url: URL) {
    NSWorkspace.shared.open(url)
  }

  public func revealAppInFinder() {
    NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
  }
}
