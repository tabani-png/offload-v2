import Foundation

// Ported from PR #44 (app/Sources/Core/Recordings.swift `ScreenPermissionGate`), which took it from
// farzaa/clicky leanring-buddy/WindowPositionManager.swift (MIT, Copyright (c) 2026 Farza; see NOTICE).
// Foundation only, so every rule is tested without TCC.

/// The two permissions setup asks for. Input Monitoring is never asked (ONBOARDING section 3).
public enum PermissionKind: String, CaseIterable, Codable, Hashable, Sendable {
  case accessibility
  case screenRecording
}

/// Where a tap on "Open Settings" goes: the system prompt once per launch, then the Privacy pane, so the person never
/// gets the prompt and the pane at the same time.
public enum ScreenPermissionGate {
  public enum Destination: Equatable, Sendable { case alreadyGranted, systemPrompt, systemSettings }

  public static func destination(hasPermissionNow: Bool, hasAttemptedSystemPrompt: Bool) -> Destination {
    if hasPermissionNow { return .alreadyGranted }
    return hasAttemptedSystemPrompt ? .systemSettings : .systemPrompt
  }

  /// `CGPreflightScreenCaptureAccess()` can return a false negative after a grant was confirmed once.
  public static func treatAsGranted(now: Bool, previouslyConfirmed: Bool) -> Bool { now || previouslyConfirmed }
}

/// System Settings pane links and control names. Apple does not document the pane URLs, so one table holds them per
/// macOS version, with the Privacy & Security root and a one-line hint as the fallback.
public enum PrivacyPane {
  static let legacyBase = "x-apple.systempreferences:com.apple.preference.security"
  static let modernBase = "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension"

  public static let knownVersions: Set<Int> = [14, 15, 26]

  public static func isKnown(macOSMajor: Int) -> Bool { knownVersions.contains(macOSMajor) }

  static func anchor(_ kind: PermissionKind) -> String {
    switch kind {
    case .accessibility: return "Privacy_Accessibility"
    case .screenRecording: return "Privacy_ScreenCapture"
    }
  }

  public static func url(for kind: PermissionKind, macOSMajor: Int) -> URL {
    let s: String
    switch macOSMajor {
    case 14: s = legacyBase + "?" + anchor(kind)
    case 15, 26: s = modernBase + "?" + anchor(kind)
    default: s = modernBase
    }
    return URL(string: s) ?? URL(fileURLWithPath: "/System/Applications/System Settings.app")
  }

  /// The control's name as the running macOS shows it.
  public static func controlName(for kind: PermissionKind, macOSMajor: Int) -> String {
    switch kind {
    case .accessibility: return "Accessibility"
    case .screenRecording: return macOSMajor >= 15 ? "Screen & System Audio Recording" : "Screen Recording"
    }
  }

  /// Shown under the row only when the pane link falls back to the Privacy & Security root.
  public static func fallbackHint(for kind: PermissionKind, macOSMajor: Int) -> String? {
    if isKnown(macOSMajor: macOSMajor) { return nil }
    switch kind {
    case .accessibility: return "Choose Accessibility, then turn on Offload."
    case .screenRecording: return "Choose Screen Recording, then turn on Offload."
    }
  }
}

/// One row on screen 2, in the order they are asked: Accessibility first (the primary text source).
public struct PermissionRow: Equatable, Sendable, Identifiable {
  public var kind: PermissionKind
  public var title: String
  public var purpose: String
  public var tag: String
  public var note: String
  public var ifMissing: String
  public var id: String { kind.rawValue }

  public static func rows(macOSMajor: Int) -> [PermissionRow] {
    [
      PermissionRow(
        kind: .accessibility,
        title: PrivacyPane.controlName(for: .accessibility, macOSMajor: macOSMajor),
        purpose: "to read window titles and the words in them, not what you type",
        tag: "needed for good results",
        note: "macOS says this lets an app control your Mac. Offload reads with it, and acts only in steps you approve.",
        ifMissing: "Without this, Offload can't see window titles or web addresses, so its picture of your work will be rougher."
      ),
      PermissionRow(
        kind: .screenRecording,
        title: PrivacyPane.controlName(for: .screenRecording, macOSMajor: macOSMajor),
        purpose: "to read apps that don't share their text",
        tag: "recommended",
        note: "macOS shows a menu bar indicator while an app reads the screen, and may ask you again from time to time. Offload keeps working from window text if you say no.",
        ifMissing: "Without this, Offload reads only apps that share their text."
      ),
    ]
  }
}
