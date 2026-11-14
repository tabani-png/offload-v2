import Foundation

// The live permission ticks on screen 2. Ported from PR #44 (Core/Onboarding.swift `update(_:)` and `justGranted`)
// and clicky (leanring-buddy/CompanionManager.swift: rows polled every 1.5 s; MIT, see NOTICE). Pure.

public struct PermissionTicker: Equatable, Sendable {
  /// Seconds between checks while screen 2 is open.
  public static let interval: Double = 1.5

  /// nil until the first read.
  public private(set) var accessibility: Bool?
  /// The raw preflight answer of the last read.
  public private(set) var screenPreflight: Bool?
  /// A Screen Recording grant was seen once; it survives a false preflight (persisted in the onboarding state).
  public private(set) var screenRecordingConfirmed: Bool
  /// Kinds that turned on while the screen was open, for the tick.
  public private(set) var justGranted: Set<PermissionKind> = []
  /// Screen Recording turned on while open: macOS needs a quit and reopen before capture works.
  public private(set) var needsRelaunch = false

  public init(screenRecordingConfirmed: Bool = false) {
    self.screenRecordingConfirmed = screenRecordingConfirmed
  }

  public var hasRead: Bool { accessibility != nil }

  public func isGranted(_ kind: PermissionKind) -> Bool {
    switch kind {
    case .accessibility: return accessibility == true
    case .screenRecording:
      return ScreenPermissionGate.treatAsGranted(now: screenPreflight == true, previouslyConfirmed: screenRecordingConfirmed)
    }
  }

  public var missing: [PermissionKind] { PermissionKind.allCases.filter { !isGranted($0) } }

  /// Applies a fresh read; returns the kinds that just turned on. The first read is not "turning on".
  @discardableResult
  public mutating func apply(accessibility ax: Bool, screenPreflight sr: Bool) -> Set<PermissionKind> {
    let firstRead = !hasRead
    let before = Set(PermissionKind.allCases.filter { isGranted($0) })
    accessibility = ax
    screenPreflight = sr
    if sr { screenRecordingConfirmed = true }
    let after = Set(PermissionKind.allCases.filter { isGranted($0) })
    guard !firstRead else { return [] }
    let new = after.subtracting(before)
    justGranted.formUnion(new)
    if new.contains(.screenRecording) { needsRelaunch = true }
    return new
  }

  /// "Show Offload in Finder": only when a row is missing and Offload is not in that row's Settings list, so the
  /// person can drag it in.
  public func showInFinder(listedInSettings: Set<PermissionKind>) -> Bool {
    missing.contains { !listedInSettings.contains($0) }
  }
}
