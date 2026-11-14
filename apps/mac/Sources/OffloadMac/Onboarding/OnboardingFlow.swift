import Foundation

/// What the person did on a screen.
public enum OnboardingAction: Equatable, Sendable {
  /// The screen's primary button (Continue, Get started, Open today).
  case next
  case back
  /// Skip on a question screen, "Skip for now" on connect, "Skip" on recordings.
  case skip
  case showSampleWeek
  /// A fresh permissions read (screen 2 polls every 1.5 s).
  case permissionsRead(accessibility: Bool, screenRecording: Bool)
  case quitAndReopen
  case signInResult(SignInResult)
  case notNow
  case startSending(noticeVersion: String)
  case keepOnThisMac
  case answer(ProfileAnswer)
  case neverWatchText(String)
  case neverWatch(add: [Exclusion])
  case neverWatchRemove(Exclusion)
  case connected(ConnectedApp)
  case importRecordings
  case setOpenAtLogin(Bool)
  /// `GET /v1/me` says the "What leaves your Mac" notice has a new version (row 11.11).
  case reconsentNeeded
}

/// What the app must do after an action. Values, so tests assert them without I/O.
public enum OnboardingEffect: Equatable, Sendable {
  case startCapture
  case startUploader
  case pauseUploader
  case recordConsent(noticeVersion: String)
  case patchProfile(ProfileUpdate)
  case applyExclusionsLocally([Exclusion])
  case removeExclusionLocally(Exclusion)
  case uploadExclusions([Exclusion])
  case setLoginItem(Bool)
  case relaunch
  case showSampleWeek
  case startRecordingsImport
  case openToday
}

/// The onboarding state machine. `perform` is the only mutator.
public struct OnboardingFlow: Equatable, Sendable {
  public private(set) var state: OnboardingState

  public init(state: OnboardingState = OnboardingState()) { self.state = state }

  public var screen: OnboardingScreen { state.screen }

  /// Whether a screen is shown at all for this state.
  public static func isOffered(_ screen: OnboardingScreen, state: OnboardingState) -> Bool {
    switch screen {
    case .whatLeaves: return state.signedIn
    // Recordings only after screen 5 was accepted; hidden in Local mode. Local mode itself jumps to screen 13
    // ("Not now", "Keep it on this Mac"), so the question screens need no rule here.
    case .recordings: return state.sending
    default: return true
    }
  }

  /// `--onboarding-screen <n>`: open the flow at a screen (test hook).
  public mutating func jump(to screen: OnboardingScreen) {
    state.screen = screen
    state.history = []
  }

  private mutating func go(_ to: OnboardingScreen) {
    if to != state.screen { state.history.append(state.screen) }
    state.screen = to
  }

  /// The next screen after `from` that is offered for this state.
  private func following(_ from: OnboardingScreen) -> OnboardingScreen {
    var s = from
    while let n = OnboardingScreen(rawValue: s.rawValue + 1) {
      if Self.isOffered(n, state: state) { return n }
      s = n
    }
    return .done
  }

  private mutating func advance() { go(following(state.screen)) }

  @discardableResult
  public mutating func perform(_ action: OnboardingAction, now: Date = Date()) -> [OnboardingEffect] {
    switch action {
    case .back:
      if let prev = state.history.popLast() { state.screen = prev }
      return []

    case .showSampleWeek:
      return [.showSampleWeek]

    case let .permissionsRead(ax, sr):
      state.accessibility = ax
      if sr { state.screenRecordingConfirmed = true }
      state.screenRecording = ScreenPermissionGate.treatAsGranted(now: sr, previouslyConfirmed: state.screenRecordingConfirmed)
      return []

    case .quitAndReopen:
      // Save the place: the relaunch resumes at screen 3 with "Screen reading is on."
      state.screenRecording = true
      state.screenRecordingConfirmed = true
      state.showScreenReadingOn = true
      state.captureStarted = true
      go(.lastTenMinutes)
      return [.relaunch]

    case .neverWatchText(let text):
      state.neverWatchText = text
      return []

    case .neverWatch(let add):
      let fresh = add.filter { $0.source == .user && !state.neverWatch.contains($0) }
      guard !fresh.isEmpty else { return [] }
      state.neverWatch += fresh
      // Applied on the Mac first; sent to the account only when sending.
      var effects: [OnboardingEffect] = [.applyExclusionsLocally(fresh)]
      if state.sending { effects.append(.uploadExclusions(fresh)) }
      return effects

    case .neverWatchRemove(let e):
      guard let i = state.neverWatch.firstIndex(of: e) else { return [] }
      state.neverWatch.remove(at: i)
      return [.removeExclusionLocally(e)]

    case .setOpenAtLogin(let on):
      state.openAtLogin = on
      return []

    case .reconsentNeeded:
      guard state.uploadConsent else { return [] }
      state.uploadConsent = false
      state.screen = .whatLeaves
      return [.pauseUploader]

    case .connected(let app):
      if !state.connectedApps.contains(where: { $0.id == app.id }) { state.connectedApps.append(app) }
      return []

    default:
      return performOnScreen(action, now: now)
    }
  }

  private mutating func performOnScreen(_ action: OnboardingAction, now: Date) -> [OnboardingEffect] {
    switch (state.screen, action) {
    case (.install, .next), (.whatItWatches, .next):
      advance()
      return []

    case (.permissions, .next):
      advance()
      // Capture starts when this screen is resolved and at least one permission is on.
      if !state.captureStarted && (state.accessibility || state.screenRecording) {
        state.captureStarted = true
        return [.startCapture]
      }
      return []

    case (.lastTenMinutes, .next):
      state.showScreenReadingOn = false
      advance()
      return []

    case (.signIn, .signInResult(let r)):
      state.lastSignInResult = r
      if r == .signedIn {
        state.signedIn = true
        advance()
      }
      return []

    case (.signIn, .notNow):
      go(.done)
      return []

    case (.whatLeaves, .startSending(let version)):
      state.uploadConsent = true
      state.consentedNoticeVersion = version
      state.includeEarlierDays = false
      if state.completed { state.screen = .done } else { advance() }
      return [.recordConsent(noticeVersion: version), .startUploader]

    case (.whatLeaves, .keepOnThisMac):
      state.uploadConsent = false
      if state.completed { state.screen = .done } else { go(.done) }
      return []

    case (.role, .answer(.role(let r))):
      let role = r.trimmingCharacters(in: .whitespacesAndNewlines)
      advance()
      guard !role.isEmpty else { return [] }
      state.profile.role = role
      return [.patchProfile(ProfileUpdate(role: role))]

    case (.goals, .answer(.goals(let g))):
      let goals = Goals.clean(g)
      advance()
      guard !goals.isEmpty else { return [] }
      state.profile.goals = goals
      return [.patchProfile(ProfileUpdate(goals: goals))]

    case (.drains, .answer(.drains(let d))):
      advance()
      guard !d.isEmpty else { return [] }
      state.profile.drains = d
      return [.patchProfile(ProfileUpdate(drains: d))]

    case (.rhythm, .answer(.rhythm(let r))):
      state.profile.rhythm = r
      advance()
      return [.patchProfile(ProfileUpdate(rhythm: r))]

    case (.handsOn, .answer(.autonomy(let a))):
      state.profile.autonomy = a
      advance()
      return [.patchProfile(ProfileUpdate(autonomy: a))]

    case (.recordings, .importRecordings):
      state.recordingsImportStarted = true
      advance()
      return [.startRecordingsImport]

    case (.done, .next):
      state.completed = true
      state.setupCompletedAt = now
      return [.setLoginItem(state.openAtLogin), .openToday]

    case (.role, .next), (.goals, .next), (.drains, .next), (.rhythm, .next), (.handsOn, .next),
         (.role, .skip), (.goals, .skip), (.drains, .skip), (.rhythm, .skip), (.handsOn, .skip),
         (.connectApps, .next), (.connectApps, .skip), (.recordings, .next), (.recordings, .skip):
      // Continue without an answer, or Skip: the field stays empty and nothing is written.
      advance()
      return []

    default:
      return []
    }
  }
}
