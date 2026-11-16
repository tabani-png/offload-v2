import Foundation

// Every onboarding and Today string, from ONBOARDING sections 4 to 9 and 13. Rules: sentences a person could say
// aloud, no exclamation marks, no em dashes, lowercase captions with "·", sentence-case headlines and buttons, no
// internal terms. `scripts/check-copy.sh` lints these literals; the COPY tests check them again.

/// Retention numbers for screen 5, from config (`OFFLOAD_TEXT_TTL_DAYS`, `OFFLOAD_RAW_TTL_DAYS`, OQ-02; the derived
/// model rule, OQ-03). Never typed into copy.
public struct RetentionConfig: Equatable, Sendable {
  public enum DerivedModelRule: Equatable, Sendable {
    case keptUntilDeleted
    case deletedAfter(days: Int)
  }

  public var textTTLDays: Int
  public var rawTTLDays: Int
  public var derivedModel: DerivedModelRule
  /// The local egress ledger on this Mac keeps every sent batch for 7 days (ADR 0035, m3-02). Not the cloud text TTL.
  public let ledgerDays = 7

  public init(textTTLDays: Int = 7, rawTTLDays: Int = 30, derivedModel: DerivedModelRule = .keptUntilDeleted) {
    self.textTTLDays = textTTLDays
    self.rawTTLDays = rawTTLDays
    self.derivedModel = derivedModel
  }

  /// From config values (the server's `GET /v1/me` once M1-04 lands; defaults until then). Bad values fall back to
  /// the defaults instead of inventing a number.
  public init(values: [String: String]) {
    func days(_ key: String) -> Int? {
      guard let v = values[key], let n = Int(v.trimmingCharacters(in: .whitespaces)), n > 0 else { return nil }
      return n
    }
    let d = RetentionConfig()
    self.init(
      textTTLDays: days("OFFLOAD_TEXT_TTL_DAYS") ?? d.textTTLDays,
      rawTTLDays: days("OFFLOAD_RAW_TTL_DAYS") ?? d.rawTTLDays,
      derivedModel: days("OFFLOAD_DERIVED_TTL_DAYS").map { .deletedAfter(days: $0) } ?? d.derivedModel
    )
  }
}

/// What one screen shows: one headline, one primary button, at most one secondary, and Skip on question screens.
public struct ScreenSpec: Equatable, Sendable {
  public var headline: String
  /// A small mark beside the headline ("new" on screen 5 after the notice changed).
  public var badge: String?
  public var body: String?
  public var caption: String?
  public var primaryTitle: String
  public var secondaryTitle: String?
  public var hasSkip: Bool
  public var skipTitle: String?
}

public enum OnboardingCopy {
  // MARK: Screen 0
  public static let installHeadline = "Offload is ready to set up."
  public static let installBody = "Setup takes about five minutes. Every step can be skipped."
  public static let moveTitle = "Move Offload to Applications"
  public static let moveBody = "Updates and permissions are unreliable when Offload runs from the disk image."
  public static let movePrimary = "Move and reopen"
  public static let moveSecondary = "Quit"
  public static let moveFailed = "Offload couldn't be copied to Applications. Drag it there in Finder, then open it from Applications."
  public static let startFreshBody = "Offload's saved data on this Mac can't be opened. Start fresh?"
  public static let startFreshPrimary = "Start fresh"
  public static let startFreshNote = "This deletes only the unreadable data on this Mac. Your account is not affected."

  // MARK: Screen 1
  public static let whatItWatchesHeadline = "It watches how you work. It keeps none of what you type."
  public static let noticesTitle = "Notices"
  public static let notices = ["Which app and window you're in", "How often you switch", "Work you do more than twice"]
  public static let neverKeepsTitle = "Never keeps"
  public static let neverKeeps = ["Keystrokes or passwords", "Banking and private windows", "Screenshots past 7 days"]
  public static let whatItWatchesCaption = "counted on your mac · nothing is sent until you say so"
  public static let getStarted = "Get started"
  public static let sampleWeek = "Look at a sample week"
  public static let sampleDataLabel = "Sample data"

  // MARK: Screen 2
  public static let permissionsHeadline = "Two switches in System Settings."
  public static let permissionsCaption = "checks every 1.5 s · ticks the moment you flip it · you can continue with any missing"
  public static let openSettings = "Open Settings"
  public static let showInFinder = "Show Offload in Finder"
  public static let showInFinderNote = "Drag Offload into the list, then turn it on."
  public static let quitAndReopen = "Quit and reopen Offload"
  public static let quitAndReopenNote = "macOS needs Offload to reopen before it can read the screen. Setup picks up where you are."
  public static let bothMissing = "You can continue now and turn these on later in Settings."

  // MARK: Screen 3
  public static let screenReadingOn = "Screen reading is on."
  public static let invitation = "keep working. i'll take notes on this mac. next, you choose what gets sent."
  public static let lastTenCaption = "counted on your mac from the last 10 minutes · no model call · nothing sent"
  public static let accessLater = "You can turn on access later in Settings."

  // MARK: Screen 4
  public static let signInHeadline = "Sign in to your Offload account."
  public static let signInBody = "Your account is where Offload learns your week and builds your fixes. One sign-in also links this Mac."
  public static let signInPrimary = "Continue in your browser"
  public static let notNow = "Not now"
  public static let signInFooter = "By continuing you agree to the Terms and Privacy Policy."
  public static let signInWaiting = "Waiting for your browser..."
  public static let signInOpenAgain = "Open the page again"
  public static func permissionOn(_ name: String) -> String { "\(name) is on." }
  public static let cancel = "Cancel"
  public static let signInTimedOut = "That took too long. Try again?"
  public static let signInOffline = "You're offline. You can continue without an account and sign in later."
  public static let signInCancelled = "Sign-in was cancelled. You can try again or continue on this Mac."
  public static let signInUnavailable = "Sign-in isn't ready in this build yet. Choose Not now to keep using Offload on this Mac."

  // MARK: Screen 5
  public static let whatLeavesHeadline = "What leaves your Mac."
  public static let sentTitle = "Sent to your Offload account, masked first"
  public static let sent = [
    "Which app and window you're in, and for how long.",
    "The words on screen. Names, emails and phone numbers become stand-ins on this Mac. Card numbers, codes and keys are removed.",
    "The website, not the full address.",
    "When you're idle, when you pause, and when a permission changes.",
    "Your answers, and your approvals.",
  ]
  public static let staysTitle = "Stays on this Mac"
  public static let stays = [
    "Screenshots. Pictures of your screen are never sent.",
    "What you type. Keys are never recorded.",
    "Anything from apps and sites you choose not to watch, and private windows.",
    "Passwords, banking apps and password managers are skipped entirely.",
    "The key that turns stand-ins back into names. Only your Macs hold it.",
  ]
  public static let privacyDetails = "Read the privacy details"
  public static let workMac = "Using a work Mac? Check your employer's policy first."
  public static let startSending = "Start sending"
  public static let keepOnThisMac = "Keep it on this Mac"
  public static let noticeChanged = "new"
  public static let consentFailed = "Offload couldn't record your choice, so nothing was sent. Try again in a moment."

  public static func retentionLine(_ c: RetentionConfig) -> String {
    let learned: String
    switch c.derivedModel {
    case .keptUntilDeleted: learned = "is kept until you delete it"
    case .deletedAfter(let d): learned = "is deleted after \(d) days"
    }
    return "Screen text is deleted after \(c.textTTLDays) days, app and window details after \(c.rawTTLDays). "
      + "What Offload learns about your work, like which tasks repeat, \(learned)."
  }

  public static func whatLeavesFacts(_ c: RetentionConfig) -> [String] {
    [
      "AI models from Anthropic read the masked text to understand your work. Offload doesn't sell your data.",
      retentionLine(c),
      "Masking is automatic and can miss things. You can see every batch sent from this Mac in the last \(c.ledgerDays) days, and delete anything from Settings.",
    ]
  }

  // MARK: Screens 6 to 9, 12
  public static let roleQuestion = "What do you do?"
  public static let roleCaption = "used to name things and write drafts in your words · never to count hours"
  public static let typeOne = "Or type one"
  public static let goalsQuestion = "What do you want more of in the next 90 days?"
  public static func goalsCaption(count: Int) -> String {
    "\(min(count, Goals.max)) of \(Goals.max) · your weekly review reports on each one"
  }
  public static let drainsQuestion = "What eats your week?"
  public static let drainsCaption = "a starting hunch · after 4 weeks your real hours take over"
  public static let rhythmQuestion = "When do you work?"
  public static let rhythmDays = "Days"
  public static let rhythmHours = "Hours"
  public static let rhythmReview = "Weekly review"
  public static let neverWatchQuestion = "What should it never watch?"
  public static let neverWatchLabel = "Never watch these apps or sites"
  public static let neverWatchHint = "Slack, mail.google.com"
  public static let neverWatchCaption = "excluded apps stop being seen within one check · no text, no frames"
  public static let neverWatchAdd = "Add"
  public static let lockedNote = "always on"
  public static func neverWatchNotFound(_ names: [String]) -> String {
    "Couldn't find \(names.joined(separator: ", ")) on this Mac. Type the website, or the app as it appears in Applications."
  }
  public static let handsOnQuestion = "How hands-on should it be?"
  public static let handsOnCaption = "change it any time · each fix still asks once"
  public static let skip = "Skip"
  public static let continueTitle = "Continue"

  // MARK: Screen 10
  public static let connectHeadline = "Connect the two apps you use most."
  public static let connectBody = "Offload reads them to find repeated work. It acts in them only after you approve."
  public static let connectCaption = "read only for now · you approve every action later"
  public static let connect = "Connect"
  public static let connectWithoutConnecting = "Continue without connecting"
  public static let skipForNow = "Skip for now"
  public static let connectGrant = "Offload will be able to read your sent mail to find patterns, and create drafts. It sends nothing without your approval."
  public static let connectCancelled = "No problem. You can connect later."
  public static let connectScopeDenied = "Offload needs read access to find patterns."
  public static let connectTimedOut = "That took too long. You can try again."
  public static let connectOffline = "You're offline. You can connect later from Settings."
  public static let connectUnavailable = "Connecting apps isn't ready in this build yet. You can connect later from Settings."

  // MARK: Screen 11
  public static let recordingsHeadline = "Already record your screen? Start with last week."
  public static let recordingsCaption = "optional · kept in its own space · wipe it in one click"
  public static let importTitle = "Import"
  public static let chooseFolder = "Choose folder…"
  public static let recordingsNotReady = "Importing recordings isn't ready in this build yet. Nothing was read."

  // MARK: Screen 13
  public static let doneHeadline = "You're set. Keep working."
  public static let openAtLoginLabel = "Open Offload when I log in"
  /// Pause arrives with the observer (m3-02); until then the pointer promises only what the menu has.
  public static let menuBarPointer = "Tell it not to watch an app, from here."
  public static let openToday = "Open today"
  public static let localBody = "Offload is watching on this Mac only. Sign in when you want your week and fixes."
  /// Local mode while this build has no capture yet (m3-02): honest about it.
  public static let localNotCapturingBody = "Your choices are saved on this Mac. Watching starts with a later update, and nothing is sent until you say so."

  public static func doneBody(state: OnboardingState, capturing: Bool = true) -> String {
    guard state.sending else { return capturing ? localBody : localNotCapturingBody }
    let rhythm = state.profile.rhythm ?? Rhythm()
    let goals = state.profile.goals.map { $0.lowercased() }
    let around: String
    switch goals.count {
    case 0: around = "your hours"
    case 1: around = goals[0]
    default: around = goals.dropLast().joined(separator: ", ") + " and " + (goals.last ?? "")
    }
    return "It learns your week as it happens. Your first review lands \(rhythm.reviewLong), built around \(around)."
  }

  // MARK: Today
  public static let todayTitle = "Today"
  public static let todayEmptyTitle = "Nothing to show yet."
  public static let todayEmptyBody = "Offload needs a few ordinary workdays to see what repeats. Keep working."
  public static let finishSettingUp = "Finish setting up"
  public static let continueSetup = "Continue setup"
  public static let bannerSignIn = "Sign in to see your week and get fixes."
  public static let bannerStartSending = "Start sending to see your week and get fixes."
  public static let signIn = "Sign in"
  public static let screenReadingOff = "Screen reading is off"
  public static let windowDetailsOff = "Window details are off"
  public static let turnOn = "Turn on"
  public static let connectedAppsOnly = "Working from your connected apps only"
  public static let dismiss = "Dismiss"

  // MARK: Menu bar
  public static let menuOpen = "Open Offload"
  public static let menuSetup = "Continue setup"
  public static let menuPause = "Pause watching"
  public static let menuNeverWatch = "Don't watch this app"
  public static func menuDontWatch(_ appName: String) -> String { "Don't watch \(appName)" }
  public static let menuNeverWatchMore = "Never watch an app or site…"
  public static let neverWatchYours = "Yours"
  public static let remove = "Remove"
  public static let menuQuit = "Quit Offload"
  public static let menuNotWatching = "not watching yet."

  // MARK: Specs

  public static func spec(for screen: OnboardingScreen, state: OnboardingState) -> ScreenSpec {
    func s(_ h: String, body: String? = nil, caption: String? = nil, primary: String = OnboardingCopy.continueTitle,
           secondary: String? = nil, skip: Bool = false, badge: String? = nil) -> ScreenSpec {
      ScreenSpec(headline: h, badge: badge, body: body, caption: caption, primaryTitle: primary, secondaryTitle: secondary,
                 hasSkip: skip, skipTitle: skip ? OnboardingCopy.skip : nil)
    }
    switch screen {
    case .install: return s(installHeadline, body: installBody)
    case .whatItWatches: return s(whatItWatchesHeadline, caption: whatItWatchesCaption, primary: getStarted, secondary: sampleWeek)
    case .permissions: return s(permissionsHeadline, caption: permissionsCaption)
    case .lastTenMinutes: return s("Here's your last 10 minutes.", caption: lastTenCaption)
    case .signIn: return s(signInHeadline, body: signInBody, caption: nil, primary: signInPrimary, secondary: notNow)
    case .whatLeaves:
      return s(whatLeavesHeadline, primary: startSending, secondary: keepOnThisMac,
               badge: state.reconsentPending ? noticeChanged : nil)
    case .role: return s(roleQuestion, caption: roleCaption, skip: true)
    case .goals: return s(goalsQuestion, caption: goalsCaption(count: state.profile.goals.count), skip: true)
    case .drains: return s(drainsQuestion, caption: drainsCaption, skip: true)
    case .rhythm: return s(rhythmQuestion, caption: neverWatchCaption, skip: true)
    case .connectApps:
      return s(connectHeadline, body: connectBody, caption: connectCaption,
               primary: state.connectedApps.isEmpty ? connectWithoutConnecting : continueTitle, secondary: skipForNow)
    case .recordings: return s(recordingsHeadline, caption: recordingsCaption, primary: importTitle, secondary: chooseFolder, skip: true)
    case .handsOn: return s(handsOnQuestion, caption: handsOnCaption, skip: true)
    case .done: return s(doneHeadline, body: doneBody(state: state), primary: openToday, secondary: sampleWeek)
    }
  }

  /// The lowercase captions, the pointer's remark style included.
  public static var captions: [String] {
    [whatItWatchesCaption, permissionsCaption, lastTenCaption, roleCaption, goalsCaption(count: 2), drainsCaption,
     neverWatchCaption, connectCaption, recordingsCaption, handsOnCaption, lockedNote, menuNotWatching]
      + BuddyMood.allCases.map(\.line)
  }

  /// Every string the onboarding and Today screens can show, for the copy tests.
  public static var allStrings: [String] {
    var s: [String] = [
      installHeadline, installBody, moveTitle, moveBody, movePrimary, moveSecondary, startFreshBody, startFreshPrimary,
      startFreshNote, whatItWatchesHeadline, noticesTitle, neverKeepsTitle, getStarted, sampleWeek, sampleDataLabel,
      permissionsHeadline, openSettings, showInFinder, showInFinderNote, quitAndReopen, quitAndReopenNote, bothMissing,
      screenReadingOn, invitation, accessLater, signInHeadline, signInBody, signInPrimary, notNow, signInFooter,
      signInWaiting, signInOpenAgain, cancel, signInTimedOut, signInOffline, signInCancelled, signInUnavailable,
      whatLeavesHeadline, sentTitle, staysTitle, privacyDetails, workMac, startSending, keepOnThisMac, noticeChanged,
      roleQuestion, typeOne, goalsQuestion, drainsQuestion, rhythmQuestion, rhythmDays, rhythmHours, rhythmReview,
      neverWatchQuestion, neverWatchLabel, neverWatchHint, neverWatchAdd, neverWatchNotFound(["Example"]),
      handsOnQuestion, skip, continueTitle, connectHeadline, connectBody, connect, connectWithoutConnecting, skipForNow,
      connectGrant, connectCancelled, connectScopeDenied, connectTimedOut, connectOffline, connectUnavailable,
      recordingsHeadline, importTitle, chooseFolder, recordingsNotReady, doneHeadline, openAtLoginLabel, menuBarPointer,
      openToday, localBody, todayTitle, todayEmptyTitle, todayEmptyBody, finishSettingUp, continueSetup, bannerSignIn,
      bannerStartSending, signIn, screenReadingOff, windowDetailsOff, turnOn, connectedAppsOnly, dismiss, menuOpen,
      menuSetup, menuPause, menuNeverWatch, menuQuit, consentFailed, permissionOn("Accessibility"), localNotCapturingBody,
      moveFailed, menuDontWatch("Slack"), menuNeverWatchMore, neverWatchYours, remove,
      TimeHeadline.detailTitle, TimeHeadline.findingsTitle, TimeHeadline.mathsTitle, TimeHeadline.findingsFooter,
      TimeHeadline.emptyLine,
    ]
    s += notices + neverKeeps + sent + stays + whatLeavesFacts(RetentionConfig()) + captions
    s += Roles.choices + Goals.choices + Drain.allCases.map(\.label)
    s += Autonomy.allCases.flatMap { [$0.label, $0.detail] }
    s += NeverWatchChip.locked.map(\.label) + NeverWatchChip.optional.map(\.label)
    s += PermissionRow.rows(macOSMajor: 15).flatMap { [$0.title, $0.purpose, $0.tag, $0.note, $0.ifMissing] }
    s += PermissionKind.allCases.compactMap { PrivacyPane.fallbackHint(for: $0, macOSMajor: 99) }
    s += ConnectionCatalog.launch.flatMap { [$0.name, $0.pathLine] }
    s += OnboardingScreen.allCases.map { spec(for: $0, state: OnboardingState()).headline }
    var sending = OnboardingState()
    sending.signedIn = true
    sending.uploadConsent = true
    s.append(doneBody(state: sending))
    s.append(LocalNowSummary.compute(events: [], now: 0).line)
    return s
  }
}

/// Where "Read the privacy details" goes until Offload's own privacy policy exists (OQ-17): the public repo's
/// privacy document.
public enum PrivacyLinks {
  public static let details = URL(string: "https://github.com/tabani-png/offload-v2/blob/main/docs/SECURITY_PRIVACY.md")!
}

/// Accessibility identifiers, the UI test hooks.
public enum A11yID {
  public static func screen(_ s: OnboardingScreen) -> String { "onboarding.\(s.rawValue)" }
  public static func primary(_ s: OnboardingScreen) -> String { "onboarding.\(s.rawValue).primary" }
  public static func secondary(_ s: OnboardingScreen) -> String { "onboarding.\(s.rawValue).secondary" }
  public static func skip(_ s: OnboardingScreen) -> String { "onboarding.\(s.rawValue).skip" }
  public static func permissionRow(_ k: PermissionKind) -> String { "onboarding.2.row.\(k.rawValue)" }
  public static let showInFinder = "onboarding.2.showInFinder"
  public static let quitAndReopen = "onboarding.2.quitAndReopen"
  public static let nowLine = "onboarding.3.line"
  public static let neverWatchField = "onboarding.9.neverWatch"
  public static func connectTile(_ id: String) -> String { "onboarding.10.app.\(id)" }
  public static let openAtLogin = "onboarding.13.openAtLogin"
  public static let todayEmpty = "today.empty"
  public static func todayBanner(_ id: String) -> String { "today.banner.\(id)" }
}

/// Sign-in waiting on screen 4: after 5 minutes, "That took too long. Try again?"
public struct SignInWait: Equatable, Sendable {
  public enum Status: Equatable, Sendable { case waiting, timedOut }
  public static let timeout: Double = 300
  public var startedAt: Date
  public init(startedAt: Date) { self.startedAt = startedAt }
  public func status(now: Date) -> Status { now.timeIntervalSince(startedAt) >= Self.timeout ? .timedOut : .waiting }
}
