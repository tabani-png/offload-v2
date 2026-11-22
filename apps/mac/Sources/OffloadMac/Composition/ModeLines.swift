// What the menu bar item says about where data goes (slice m3-14-mac-app-integration, reviews 1 and 2). GLOSSARY
// "Local mode": signed out, or signed in without upload consent, so nothing is uploaded. The test build runs in Local
// mode and has no on-device text reading yet (m3-10), so it says both instead of looking broken. PRODUCT copy rules:
// plain words, no em dashes, an unbuilt feature says "coming". Shown as plain text items (VoiceOver reads them as
// text, not as dimmed buttons).
public enum ModeLines {
  public static let local = "Local mode: nothing leaves this Mac"
  public static let importComing = "Recordings import is coming: it needs on-device text reading"
  public static let importAfterSending = "Recordings import starts after Start sending"

  /// Local mode first; then why the recordings import is not offered, if it is not.
  public static func lines(local isLocal: Bool, importerReady: Bool, importOffered: Bool) -> [String] {
    var out: [String] = []
    if isLocal { out.append(Self.local) }
    if !importerReady {
      out.append(Self.importComing)
    } else if !importOffered {
      out.append(Self.importAfterSending)
    }
    return out
  }
}

/// When the recordings import is offered (screen 11, Settings, the menu bar item), by where its data goes:
/// - through the uploader: only while the person is sending, with no new notice waiting (ONBOARDING section 8);
/// - on this Mac (m3-10's local sink): whenever that sink exists, in Local mode too, since nothing leaves the Mac
///   (owner goal 2026-11-22; a divergence from ONBOARDING section 8 recorded in the SPEC).
public enum ImportOffer {
  public static func isOffered(choice: ImportSinkChoice, hasOnDeviceSink: Bool, uploadsAvailable: Bool,
                               state: OnboardingState) -> Bool {
    switch choice {
    case .uploader: return uploadsAvailable && state.sending && !state.reconsentPending
    case .onDevice: return hasOnDeviceSink
    }
  }
}
