import Foundation

/// Screen 2's live model: polls the probe every 1.5 s while the screen is open and publishes the ticks. The poll is a
/// task on the main actor; tests call `tick()` directly instead.
@MainActor
public final class PermissionsModel: ObservableObject {
  @Published public private(set) var ticker: PermissionTicker
  /// Kinds whose system prompt was shown this launch (the prompt is shown at most once per launch).
  @Published public private(set) var attemptedPrompt: Set<PermissionKind> = []
  /// Kinds whose Settings list already holds Offload, from earlier launches (saved in the onboarding state).
  private let listedBefore: Set<PermissionKind>

  private let probe: PermissionProbe
  private var pollTask: Task<Void, Never>?

  public init(probe: PermissionProbe, screenRecordingConfirmed: Bool, listedInSettings: Set<PermissionKind> = []) {
    self.probe = probe
    self.ticker = PermissionTicker(screenRecordingConfirmed: screenRecordingConfirmed)
    self.listedBefore = listedInSettings
  }

  /// Rows whose System Settings list holds Offload: prompted this launch or in an earlier one.
  public var listedInSettings: Set<PermissionKind> { listedBefore.union(attemptedPrompt) }

  /// The observer's frame requests failed: Screen Recording is off whatever one preflight says.
  public func screenCaptureFailed() {
    var t = ticker
    t.screenCaptureFailed()
    ticker = t
  }

  public var macOSMajor: Int { probe.macOSMajor }
  public var rows: [PermissionRow] { PermissionRow.rows(macOSMajor: probe.macOSMajor) }

  /// One check of both rows.
  @discardableResult
  public func tick() -> Set<PermissionKind> {
    var t = ticker
    let new = t.apply(accessibility: probe.isAccessibilityTrusted(), screenPreflight: probe.screenCapturePreflight())
    ticker = t
    return new
  }

  public func startPolling(onChange: @escaping @MainActor @Sendable (PermissionTicker) -> Void) {
    pollTask?.cancel()
    tick()
    onChange(ticker)
    pollTask = Task { @MainActor [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: UInt64(PermissionTicker.interval * 1_000_000_000))
        guard let self, !Task.isCancelled else { return }
        let before = self.ticker
        self.tick()
        if self.ticker != before { onChange(self.ticker) }
      }
    }
  }

  public func stopPolling() {
    pollTask?.cancel()
    pollTask = nil
  }

  /// "Open Settings": the system prompt once per launch, then the right Privacy pane. Returns where it went, so the
  /// caller can save that Offload is now in the list.
  @discardableResult
  public func openSettings(for kind: PermissionKind) -> ScreenPermissionGate.Destination {
    let destination = ScreenPermissionGate.destination(hasPermissionNow: ticker.isGranted(kind),
                                                       hasAttemptedSystemPrompt: attemptedPrompt.contains(kind))
    switch destination {
    case .alreadyGranted:
      break
    case .systemPrompt:
      attemptedPrompt.insert(kind)
      switch kind {
      case .accessibility: probe.promptAccessibility()
      case .screenRecording: probe.requestScreenCapture()
      }
    case .systemSettings:
      probe.openSettings(PrivacyPane.url(for: kind, macOSMajor: probe.macOSMajor))
    }
    return destination
  }

  /// What the row shows: "on" once it ticks, else its button.
  public func rowStatus(_ kind: PermissionKind) -> String {
    ticker.isGranted(kind) ? "on" : OnboardingCopy.openSettings
  }

  public var showInFinder: Bool { ticker.showInFinder(listedInSettings: listedInSettings) }

  public func revealInFinder() { probe.revealAppInFinder() }
}
