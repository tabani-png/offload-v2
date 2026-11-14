import Foundation

/// The 14 onboarding screens (ONBOARDING section 2). Screen 9 holds both Q4 (rhythm) and Q5 (never watch).
public enum OnboardingScreen: Int, CaseIterable, Codable, Comparable, Hashable, Sendable {
  case install = 0
  case whatItWatches
  case permissions
  case lastTenMinutes
  case signIn
  case whatLeaves
  case role
  case goals
  case drains
  case rhythm
  case connectApps
  case recordings
  case handsOn
  case done

  public static func < (a: OnboardingScreen, b: OnboardingScreen) -> Bool { a.rawValue < b.rawValue }

  /// The one-tap question screens: Skip is always visible and writes nothing.
  public var isQuestion: Bool {
    switch self {
    case .role, .goals, .drains, .rhythm, .handsOn: return true
    default: return false
    }
  }
}

/// How sign-in ended (screen 4). The account service behind it lands in M1-04.
public enum SignInResult: String, Codable, Equatable, Sendable {
  case signedIn
  case cancelled
  case offline
  /// This build has no sign-in yet: the screen says so and offers Local mode.
  case unavailable
}

/// A connected app on screen 10.
public struct ConnectedApp: Codable, Equatable, Hashable, Sendable {
  public var id: String
  public var account: String
  public init(id: String, account: String) {
    self.id = id
    self.account = account
  }
}

/// Everything onboarding knows, saved after every action so a quit or the Screen Recording relaunch resumes where it
/// stopped (ONBOARDING section 1 rules, 11.1, 11.8).
public struct OnboardingState: Codable, Equatable, Sendable {
  public var screen: OnboardingScreen = .install
  /// Screens left behind, for Back.
  public var history: [OnboardingScreen] = []
  public var completed = false
  public var setupCompletedAt: Date?

  public var signedIn = false
  public var lastSignInResult: SignInResult?
  /// Upload consent: "Start sending" on screen 5 for `consentedNoticeVersion`.
  public var uploadConsent = false
  public var consentedNoticeVersion: String?
  /// "Include the last few days" (OQ-26): off by default; data captured before consent stays on the Mac.
  public var includeEarlierDays = false

  public var accessibility = false
  public var screenRecording = false
  /// A Screen Recording grant was seen once (survives a CGPreflight false negative across launches).
  public var screenRecordingConfirmed = false
  /// Set by "Quit and reopen Offload"; screen 3 shows "Screen reading is on." once after the relaunch.
  public var showScreenReadingOn = false
  public var captureStarted = false

  public var profile = ProfileAnswers()
  /// What was typed in the Never watch field (kept across Back and relaunch).
  public var neverWatchText = ""
  /// The person's own Never watch entries (built-ins are not stored here).
  public var neverWatch: [Exclusion] = []
  public var connectedApps: [ConnectedApp] = []
  public var recordingsImportStarted = false
  /// "Open Offload when I log in": on by default.
  public var openAtLogin = true
  public var reask = ReaskState()

  public init() {}

  /// Signed in and sending.
  public var sending: Bool { signedIn && uploadConsent }

  public var mode: ProductMode {
    ProductMode.derive(sending: sending, accessibility: accessibility, screenRecording: screenRecording,
                       appsConnected: !connectedApps.isEmpty)
  }
}

/// Product modes (ONBOARDING section 10.1).
public enum ProductMode: String, CaseIterable, Codable, Sendable {
  case full, watching, textOnly, screenOnly, connectedAppsOnly, dormant, local

  public static func derive(sending: Bool, accessibility: Bool, screenRecording: Bool, appsConnected: Bool) -> ProductMode {
    guard sending else { return .local }
    switch (accessibility, screenRecording) {
    case (true, true): return appsConnected ? .full : .watching
    case (true, false): return .textOnly
    case (false, true): return .screenOnly
    case (false, false): return appsConnected ? .connectedAppsOnly : .dormant
    }
  }

  public var displayName: String {
    switch self {
    case .full: return "Full"
    case .watching: return "Watching"
    case .textOnly: return "Text only"
    case .screenOnly: return "Screen only"
    case .connectedAppsOnly: return "Connected apps only"
    case .dormant: return "Dormant"
    case .local: return "Local"
    }
  }
}

/// Limits on re-asking (ONBOARDING section 10.3), saved with the onboarding state.
public struct ReaskState: Codable, Equatable, Sendable {
  /// Permissions already notified about while missing.
  public var notified: Set<PermissionKind> = []
  public var dismissedBanners: [String: Date] = [:]
  public var dormantReminders = 0

  public init() {}

  /// True (and recorded) when one notification for this missing permission may be sent: at most one, ever, unless
  /// the grant was given and later lost.
  public mutating func notify(_ kind: PermissionKind) -> Bool {
    if notified.contains(kind) { return false }
    notified.insert(kind)
    return true
  }

  /// A grant was given and then lost: one more notification is allowed.
  public mutating func grantLost(_ kind: PermissionKind) { notified.remove(kind) }

  public mutating func dismiss(_ bannerID: String, at date: Date) { dismissedBanners[bannerID] = date }

  /// A dismissed banner stays dismissed for 30 days.
  public func bannerVisible(_ bannerID: String, now: Date) -> Bool {
    guard let at = dismissedBanners[bannerID] else { return true }
    return now.timeIntervalSince(at) >= Double(ReaskPolicy.bannerQuietDays) * 86_400
  }

  /// In Dormant mode, reminders stop after the second.
  public mutating func dormantReminder() -> Bool {
    guard dormantReminders < ReaskPolicy.dormantReminderLimit else { return false }
    dormantReminders += 1
    return true
  }
}

public enum ReaskPolicy {
  public static let bannerQuietDays = 30
  public static let dormantReminderLimit = 2

  /// No modal dialog re-asks for anything after setup.
  public static func mayShowModal(setupCompleted: Bool) -> Bool { !setupCompleted }
}
