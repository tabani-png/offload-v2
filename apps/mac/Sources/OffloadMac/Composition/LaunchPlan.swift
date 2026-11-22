// What starts when the app launches (slice m3-14-mac-app-integration), decided in one pure function from the saved
// onboarding state. ONBOARDING sections 10 and 11; GLOSSARY "Local mode". AppModel calls it after its launch-time
// permission read and notice check; AppComposition calls it with the same facts to choose the import sink.

/// Where a recordings import's observations go.
public enum ImportSinkChoice: Equatable, Sendable {
  /// The import space stays on this Mac (m3-10's local store; none in this slice, so no import is built).
  case onDevice
  /// Through the uploader, the Mac's only way out (ADR 0035), as `source = "import"` with the `import_id`.
  case uploader
}

public struct LaunchFacts: Equatable, Sendable {
  /// Screen 2 was resolved with a permission on (`OnboardingState.captureStarted`).
  public var captureConsented: Bool
  /// Signed in and "Start sending" accepted.
  public var sending: Bool
  /// A "What leaves your Mac" version waits to be accepted (row 11.11).
  public var reconsentPending: Bool
  /// The local buffer can be opened (row 11.6).
  public var bufferReadable: Bool
  /// This Mac has a backend to send to (`BackendMode.cloud`).
  public var uploadsAvailable: Bool

  public init(captureConsented: Bool, sending: Bool, reconsentPending: Bool, bufferReadable: Bool, uploadsAvailable: Bool) {
    self.captureConsented = captureConsented
    self.sending = sending
    self.reconsentPending = reconsentPending
    self.bufferReadable = bufferReadable
    self.uploadsAvailable = uploadsAvailable
  }

  /// From the saved state. A known notice version other than the accepted one counts as a pending re-consent, even
  /// before AppModel has marked it (the composition root reads the state before AppModel exists).
  public init(state: OnboardingState, uploadsAvailable: Bool, bufferReadable: Bool, currentNoticeVersion: String?) {
    let noticeChanged = state.uploadConsent && currentNoticeVersion != nil
      && currentNoticeVersion != state.consentedNoticeVersion
    self.init(captureConsented: state.captureStarted, sending: state.sending,
              reconsentPending: state.reconsentPending || noticeChanged, bufferReadable: bufferReadable,
              uploadsAvailable: uploadsAvailable)
  }
}

public struct LaunchPlan: Equatable, Sendable {
  public var startUpdater: Bool
  public var startCapture: Bool
  public var startUploader: Bool
  public var importSink: ImportSinkChoice

  public init(startUpdater: Bool, startCapture: Bool, startUploader: Bool, importSink: ImportSinkChoice) {
    self.startUpdater = startUpdater
    self.startCapture = startCapture
    self.startUploader = startUploader
    self.importSink = importSink
  }

  /// - updater: always (Sparkle sends no observation; it is how fixes reach the Mac).
  /// - capture: after screen 2, with a readable buffer. Capture is local; the observer follows later permission changes.
  /// - uploader: on a Mac with a backend, for a person who is sending, never while a new notice waits, never without
  ///   a readable buffer. Never in Local mode.
  /// - import sink: the uploader exactly when the uploader may run; otherwise the import space stays on the Mac.
  public static func decide(_ facts: LaunchFacts) -> LaunchPlan {
    let uploads = facts.uploadsAvailable && facts.sending && !facts.reconsentPending && facts.bufferReadable
    return LaunchPlan(startUpdater: true, startCapture: facts.captureConsented && facts.bufferReadable,
                      startUploader: uploads, importSink: uploads ? .uploader : .onDevice)
  }
}
