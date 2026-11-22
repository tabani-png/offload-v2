// What the menu bar item says about where data goes (slice m3-14-mac-app-integration, reviews 1 and 2). GLOSSARY
// "Local mode": signed out, or signed in without upload consent, so nothing is uploaded. The test build runs in Local
// mode and has no on-device text reading yet (m3-10), so it says both instead of looking broken. PRODUCT copy rules:
// plain words, no em dashes, an unbuilt feature says "coming". Shown as plain text items (VoiceOver reads them as
// text, not as dimmed buttons).
public enum ModeLines {
  public static let local = "Local mode: nothing leaves this Mac"
  public static let importComing = "Recordings import is coming: it needs on-device text reading"
  public static let importAfterSending = "Recordings import starts after Start sending"
  /// An on-device import held back until setup is past screen 2 (ImportOffer): sending has nothing to do with it.
  public static let importAfterSetup = "Recordings import opens once the first setup steps are done"
  /// Capture was asked to start and could not (for example macOS refused the saved key Offload keeps in the
  /// Keychain). Generic on purpose: the error itself is never shown or logged (review 6, finding 4).
  public static let captureOff = "Not watching: Offload could not open its storage on this Mac. Quit and open it again"

  /// Local mode first; then why the recordings import is not offered, if it is not: no importer yet, or (by where the
  /// import goes) not sending yet for the uploader, setup not far enough for the on-device import.
  public static func lines(local isLocal: Bool, importerReady: Bool, importOffered: Bool,
                           choice: ImportSinkChoice) -> [String] {
    var out: [String] = []
    if isLocal { out.append(Self.local) }
    if !importerReady {
      out.append(Self.importComing)
    } else if !importOffered {
      out.append(choice == .uploader ? Self.importAfterSending : Self.importAfterSetup)
    }
    return out
  }
}

/// When the recordings import is offered (screen 11, Settings, the menu bar item), by where its data goes:
/// - through the uploader: only while the person is sending, with no new notice waiting (ONBOARDING section 8);
/// - on this Mac (m3-10's local sink): when that sink exists and onboarding is past screen 2 (or done), in Local mode
///   too, since nothing leaves the Mac (owner goal 2026-11-22; a divergence from ONBOARDING section 8 recorded in the
///   SPEC). Never before screens 1 and 2, so no folder is read and no prompt appears at a first launch.
public enum ImportOffer {
  public static func isOffered(choice: ImportSinkChoice, hasOnDeviceSink: Bool, uploadsAvailable: Bool,
                               state: OnboardingState) -> Bool {
    switch choice {
    case .uploader: return uploadsAvailable && state.sending && !state.reconsentPending
    case .onDevice: return hasOnDeviceSink && (state.completed || state.screen > .permissions)
    }
  }
}
