import Foundation
import Testing
@testable import OffloadMac

// The onboarding state machine (ONBOARDING sections 2, 4 to 9, 10.2 and 11). Pure: actions in, effects out.

extension M304 {
  @Test("ONBOARDING: the happy path visits screens 0 to 13 in order")
  func happyPath() {
    var f = OnboardingFlow()
    var seen: [OnboardingScreen] = [f.screen]
    let actions: [OnboardingAction] = M304Path.toWhatLeaves + [
      .startSending(noticeVersion: "1"),
      .answer(.role("Founder")),
      .answer(.goals(["Ship a product", "More deep work"])),
      .answer(.drains([.email, .meetings])),
      .answer(.rhythm(Rhythm())),
      .connected(ConnectedApp(id: "gmail", account: "sample account")),
      .next,
      .skip,
      .answer(.autonomy(.draft)),
    ]
    for a in actions {
      f.perform(a, now: M304Clock.now)
      if seen.last != f.screen { seen.append(f.screen) }
    }
    #expect(seen.map(\.rawValue) == Array(0...13))
    #expect(OnboardingScreen.allCases.count == 14)
    #expect(!f.state.completed)
    let done = f.perform(.next, now: M304Clock.now)
    #expect(f.state.completed)
    #expect(f.state.setupCompletedAt == M304Clock.now)
    #expect(done.contains(.setLoginItem(true)))
    #expect(done.contains(.openToday))
    #expect(f.state.mode == .full)
  }

  @Test("ONBOARDING: \"Not now\" on sign in goes to Local mode and skips screens 5 to 12")
  func notNowIsLocal() {
    var f = OnboardingFlow()
    let effects = f.run(Array(M304Path.toWhatLeaves.prefix(5)) + [.notNow])
    #expect(f.screen == .done)
    #expect(f.state.mode == .local)
    #expect(!f.state.signedIn)
    #expect(!effects.contains(.startUploader))
    #expect(OnboardingCopy.doneBody(state: f.state) == "Offload is watching on this Mac only. Sign in when you want your week and fixes.")
  }

  @Test("ONBOARDING: \"Keep it on this Mac\" goes to Local mode, signed in, and skips screens 6 to 12")
  func keepOnMacIsLocal() {
    var f = OnboardingFlow()
    let effects = f.run(M304Path.toWhatLeaves + [.keepOnThisMac])
    #expect(f.screen == .done)
    #expect(f.state.signedIn)
    #expect(!f.state.uploadConsent)
    #expect(f.state.mode == .local)
    #expect(!effects.contains(.startUploader))
    #expect(!effects.contains { if case .recordConsent = $0 { return true } else { return false } })
  }

  @Test("ONBOARDING: every question screen has Skip, and skipping writes no profile field")
  func skipWritesNothing() {
    var f = OnboardingFlow()
    f.run(M304Path.toWhatLeaves + [.startSending(noticeVersion: "1")])
    #expect(f.screen == .role)
    let questions: [OnboardingScreen] = [.role, .goals, .drains, .rhythm, .handsOn]
    var effects: [OnboardingEffect] = []
    while f.screen != .done {
      if questions.contains(f.screen) {
        #expect(OnboardingCopy.spec(for: f.screen, state: f.state).hasSkip, "screen \(f.screen.rawValue) has no Skip")
      }
      effects += f.perform(.skip, now: M304Clock.now)
    }
    #expect(!effects.contains { if case .patchProfile = $0 { return true } else { return false } })
    #expect(f.state.profile == ProfileAnswers())
    for q in questions {
      #expect(OnboardingCopy.spec(for: q, state: f.state).skipTitle == "Skip")
    }
  }

  @Test("ONBOARDING: an answer writes only its own profile field")
  func answerWritesOneField() {
    var f = OnboardingFlow()
    f.run(M304Path.toWhatLeaves + [.startSending(noticeVersion: "1")])
    let role = f.perform(.answer(.role("Engineer")), now: M304Clock.now)
    #expect(role == [.patchProfile(ProfileUpdate(role: "Engineer"))])
    #expect(ProfileUpdate(role: "Engineer").fieldNames == ["role"])
    let goals = f.perform(.answer(.goals(["Less admin"])), now: M304Clock.now)
    #expect(goals == [.patchProfile(ProfileUpdate(goals: ["Less admin"]))])
    #expect(ProfileUpdate(goals: ["Less admin"]).fieldNames == ["goals"])
    let drains = f.perform(.answer(.drains([.contextSwitching])), now: M304Clock.now)
    #expect(drains == [.patchProfile(ProfileUpdate(drains: [.contextSwitching]))])
    #expect(Drain.contextSwitching.rawValue == "context_switching")
    #expect(Drain.agentBabysitting.label == "Coding-agent babysitting")
    let rhythm = f.perform(.answer(.rhythm(Rhythm())), now: M304Clock.now)
    #expect(rhythm == [.patchProfile(ProfileUpdate(rhythm: Rhythm()))])
    #expect(ProfileUpdate(rhythm: Rhythm()).fieldNames == ["schedule", "timezone", "review_slot"])
    #expect(Autonomy.runApproved.rawValue == "run_approved")
  }

  @Test("ONBOARDING: goals keep at most 3, each one line of at most 80 characters")
  func goalsRules() {
    let long = String(repeating: "a", count: 95)
    let cleaned = Goals.clean(["  Ship a product ", "", "More deep work\nand rest", long, "Fourth"])
    #expect(cleaned.count == 3)
    #expect(cleaned[0] == "Ship a product")
    #expect(cleaned[1] == "More deep work")
    #expect(cleaned[2].count == 80)
    #expect(Goals.max == 3 && Goals.maxLength == 80)
    #expect(Goals.choices == ["Ship a product", "More deep work", "Close customers", "Less admin", "Learn something new"])
  }

  @Test("ONBOARDING: rhythm defaults are Mon to Fri, 9:00 AM to 6:00 PM, review Fri 4:00 PM")
  func rhythmDefaults() {
    let r = Rhythm()
    #expect(r.days == [.mon, .tue, .wed, .thu, .fri])
    #expect(r.start == "09:00" && r.end == "18:00")
    #expect(r.reviewDay == .fri && r.reviewTime == "16:00")
    #expect(r.daysText == "Mon to Fri")
    #expect(r.hoursText == "9:00 AM to 6:00 PM")
    #expect(r.reviewText == "Fri 4:00 PM")
    #expect(Rhythm.clock("00:30") == "12:30 AM")
    #expect(Rhythm.clock("12:00") == "12:00 PM")
  }

  @Test("ONBOARDING: state survives quit and relaunch and resumes at the same screen")
  @MainActor func survivesRelaunch() async {
    let fakes = M304Services()
    let first = fakes.model()
    for a in M304Path.toWhatLeaves { await first.perform(a) }
    await first.perform(.startSending(noticeVersion: "1"))
    await first.perform(.answer(.role("Designer")))
    #expect(first.flow.screen == .goals)
    // A new model over the same store is a relaunch.
    let second = fakes.model()
    #expect(second.flow.screen == .goals)
    #expect(second.flow.state.profile.role == "Designer")
    #expect(second.flow.state.uploadConsent)
    // The UserDefaults store round-trips the same state.
    let suite = "m304-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    let store = UserDefaultsOnboardingStore(defaults: defaults)
    store.save(first.flow.state)
    #expect(UserDefaultsOnboardingStore(defaults: defaults).load() == first.flow.state)
    defaults.removePersistentDomain(forName: suite)
  }

  @Test("ONBOARDING: after the Screen Recording relaunch it resumes at screen 3 with \"Screen reading is on.\"")
  @MainActor func resumesAtThree() async {
    let fakes = M304Services()
    let model = fakes.model()
    await model.perform(.next)
    await model.perform(.next)
    await model.perform(.permissionsRead(accessibility: true, screenRecording: true))
    await model.perform(.quitAndReopen)
    #expect(fakes.relauncher.relaunches == 1)
    let relaunched = fakes.model()
    #expect(relaunched.flow.screen == .lastTenMinutes)
    #expect(relaunched.flow.state.showScreenReadingOn)
    #expect(OnboardingCopy.screenReadingOn == "Screen reading is on.")
    #expect(LaunchRoute.decide(options: LaunchOptions(), state: relaunched.flow.state, bundlePath: "/Applications/Offload.app",
                               bufferReadable: true, currentNoticeVersion: nil) == .onboarding(.lastTenMinutes))
    await relaunched.perform(.next)
    #expect(!relaunched.flow.state.showScreenReadingOn)
  }

  @Test("ONBOARDING: nothing is uploaded before \"Start sending\"; data captured earlier stays local")
  @MainActor func nothingUploadedBeforeConsent() async {
    var f = OnboardingFlow()
    let before = f.run(M304Path.toWhatLeaves + [.neverWatch(add: [Exclusion(kind: .bundleID, value: "com.apple.MobileSMS")])])
    #expect(!before.contains(.startUploader))
    #expect(!before.contains { if case .uploadExclusions = $0 { return true } else { return false } })
    #expect(!before.contains { if case .patchProfile = $0 { return true } else { return false } })
    let after = f.perform(.startSending(noticeVersion: "2026-11-14"), now: M304Clock.now)
    // The Never watch entry made before consent reaches the account only now, after consent (review 2 finding 9).
    #expect(after == [.recordConsent(noticeVersion: "2026-11-14"), .startUploader,
                      .uploadExclusions([Exclusion(kind: .bundleID, value: "com.apple.MobileSMS")])])
    #expect(!f.state.includeEarlierDays)

    let fakes = M304Services()
    let model = fakes.model()
    for a in M304Path.toWhatLeaves { await model.perform(a) }
    #expect(fakes.uploader.starts == 0)
    #expect(fakes.consent.recorded.isEmpty)
    await model.perform(.startSending(noticeVersion: "2026-11-14"))
    #expect(fakes.consent.recorded == ["2026-11-14"])
    #expect(fakes.uploader.starts == 1)
  }

  @Test("ONBOARDING: screen 5 retention numbers equal OFFLOAD_TEXT_TTL_DAYS, OFFLOAD_RAW_TTL_DAYS and the derived-model rule from config")
  func retentionFromConfig() {
    let defaults = RetentionConfig()
    #expect(defaults.textTTLDays == 7 && defaults.rawTTLDays == 30)
    #expect(OnboardingCopy.retentionLine(defaults)
            == "Screen text is deleted after 7 days, app and window details after 30. What Offload learns about your work, like which tasks repeat, is kept until you delete it.")
    let c = RetentionConfig(values: ["OFFLOAD_TEXT_TTL_DAYS": "5", "OFFLOAD_RAW_TTL_DAYS": "21", "OFFLOAD_DERIVED_TTL_DAYS": "90"])
    #expect(c.textTTLDays == 5 && c.rawTTLDays == 21)
    #expect(c.derivedModel == .deletedAfter(days: 90))
    let line = OnboardingCopy.retentionLine(c)
    #expect(line.contains("after 5 days"))
    #expect(line.contains("after 21."))
    #expect(line.contains("is deleted after 90 days"))
    #expect(OnboardingCopy.whatLeavesFacts(c).contains(line))
    // Bad values fall back to the defaults instead of inventing a number.
    #expect(RetentionConfig(values: ["OFFLOAD_TEXT_TTL_DAYS": "abc", "OFFLOAD_RAW_TTL_DAYS": "-3"]) == RetentionConfig())
  }

  @Test("ONBOARDING: Input Monitoring is never requested during setup")
  @MainActor func noInputMonitoring() {
    let banned = try! Regex("IOHIDRequestAccess|IOHIDCheckAccess|CGRequestListenEventAccess|CGPreflightListenEventAccess|kIOHIDRequestTypeListenEvent|Privacy_ListenEvent")
    let sources = M304Repo.swiftSources("Sources/OffloadMac")
    #expect(sources.count > 5)
    for f in sources {
      #expect(f.text.firstMatch(of: banned) == nil, "Input Monitoring API in \(f.path)")
    }
    #expect(PermissionKind.allCases == [.accessibility, .screenRecording])
    let probe = FakePermissionProbe()
    let perms = PermissionsModel(probe: probe, screenRecordingConfirmed: false)
    perms.tick()
    perms.openSettings(for: .accessibility)
    perms.openSettings(for: .screenRecording)
    let allowed: Set<String> = ["isAccessibilityTrusted", "screenCapturePreflight", "promptAccessibility", "requestScreenCapture", "openSettings"]
    #expect(probe.calls.allSatisfy { allowed.contains($0) })
  }

  @Test("ONBOARDING: capture starts when the permissions screen is resolved with at least one permission on")
  func captureStarts() {
    var none = OnboardingFlow()
    let noneEffects = none.run([.next, .next, .permissionsRead(accessibility: false, screenRecording: false), .next])
    #expect(none.screen == .lastTenMinutes)
    #expect(!noneEffects.contains(.startCapture))
    var one = OnboardingFlow()
    let early = one.run([.next, .next, .permissionsRead(accessibility: true, screenRecording: false)])
    #expect(!early.contains(.startCapture))  // not while the screen is open
    let resolved = one.perform(.next, now: M304Clock.now)
    #expect(resolved == [.startCapture])
    #expect(one.state.mode == .local)
  }

  @Test("ONBOARDING: sign in waits for the browser, times out after 5 minutes and says when offline")
  func signInStates() {
    let w = SignInWait(startedAt: M304Clock.now)
    #expect(w.status(now: M304Clock.now.addingTimeInterval(299)) == .waiting)
    #expect(w.status(now: M304Clock.now.addingTimeInterval(300)) == .timedOut)
    #expect(SignInWait.timeout == 300)
    #expect(OnboardingCopy.signInWaiting == "Waiting for your browser...")
    #expect(OnboardingCopy.signInTimedOut == "That took too long. Try again?")
    #expect(OnboardingCopy.signInOffline == "You're offline. You can continue without an account and sign in later.")
    var f = OnboardingFlow()
    f.run(Array(M304Path.toWhatLeaves.prefix(5)) + [.signInResult(.offline)])
    #expect(f.screen == .signIn)
    #expect(f.state.lastSignInResult == .offline)
    f.perform(.signInResult(.cancelled), now: M304Clock.now)
    #expect(f.screen == .signIn)
  }

  @Test("ONBOARDING: screen 13 names the review slot and the goals; with no goals it is built around your hours")
  func doneCopy() {
    var s = OnboardingState()
    s.signedIn = true
    s.uploadConsent = true
    s.profile.goals = ["Ship a product", "More deep work"]
    #expect(OnboardingCopy.doneBody(state: s)
            == "It learns your week as it happens. Your first review lands Friday at 4:00 PM, built around ship a product and more deep work.")
    s.profile.goals = []
    s.profile.rhythm = Rhythm(reviewDay: .mon, reviewTime: "09:30")
    #expect(OnboardingCopy.doneBody(state: s)
            == "It learns your week as it happens. Your first review lands Monday at 9:30 AM, built around your hours.")
    #expect(OnboardingCopy.doneHeadline == "You're set. Keep working.")
    #expect(OnboardingCopy.menuBarPointer == "Tell it not to watch an app, from here.")
  }

  @Test("ONBOARDING: Open Offload when I log in is on by default and is applied on Open today")
  @MainActor func openAtLogin() async {
    #expect(OnboardingState().openAtLogin)
    var f = OnboardingFlow()
    f.run(Array(M304Path.toWhatLeaves.prefix(5)) + [.notNow, .setOpenAtLogin(false)])
    let effects = f.perform(.next, now: M304Clock.now)
    #expect(effects.contains(.setLoginItem(false)))
    let fakes = M304Services()
    let model = fakes.model()
    for a in Array(M304Path.toWhatLeaves.prefix(5)) + [.notNow, .next] { await model.perform(a) }
    #expect(fakes.loginItem.set == [true])
    #expect(model.flow.state.completed)
  }

  @Test("ONBOARDING: a changed notice version shows screen 5 again before uploads continue")
  func reconsent() {
    var f = OnboardingFlow()
    f.run(M304Path.toWhatLeaves + [.startSending(noticeVersion: "1"), .skip, .skip, .skip, .skip, .skip, .skip, .skip, .next])
    #expect(f.state.completed)
    #expect(LaunchRoute.decide(options: LaunchOptions(), state: f.state, bundlePath: "/Applications/Offload.app",
                               bufferReadable: true, currentNoticeVersion: "1") == .today)
    #expect(LaunchRoute.decide(options: LaunchOptions(), state: f.state, bundlePath: "/Applications/Offload.app",
                               bufferReadable: true, currentNoticeVersion: "2") == .onboarding(.whatLeaves))
    let paused = f.perform(.reconsentNeeded, now: M304Clock.now)
    #expect(paused == [.pauseUploader])
    #expect(f.screen == .whatLeaves)
    #expect(f.state.mode == .local)
    let again = f.perform(.startSending(noticeVersion: "2"), now: M304Clock.now)
    #expect(again == [.recordConsent(noticeVersion: "2"), .startUploader])
    #expect(f.state.completed)
    #expect(f.state.consentedNoticeVersion == "2")
  }

  @Test("ONBOARDING: an abandoned setup reopens at the first unfinished screen and Today shows Finish setting up")
  func abandoned() {
    var f = OnboardingFlow()
    f.run(Array(M304Path.toWhatLeaves.prefix(4)))
    #expect(f.screen == .lastTenMinutes)
    #expect(LaunchRoute.decide(options: LaunchOptions(), state: f.state, bundlePath: "/Applications/Offload.app",
                               bufferReadable: true, currentNoticeVersion: nil) == .onboarding(.lastTenMinutes))
    let today = TodayModel(state: f.state, now: M304Clock.now)
    #expect(today.banners.contains { $0.id == TodayBanner.finishSettingUpID })
    #expect(OnboardingCopy.finishSettingUp == "Finish setting up")
  }

  @Test("ONBOARDING: Reduce Motion shows the typed invitation and the remark in their final state")
  func reduceMotion() {
    let text = OnboardingCopy.invitation
    #expect(text == "keep working. i'll take notes on this mac. next, you choose what gets sent.")
    #expect(TypedText.visible(text, elapsed: 0, reduceMotion: true) == text)
    #expect(TypedText.visible(text, elapsed: 0.028 * 4, reduceMotion: false) == "keep")
    #expect(TypedText.visible(text, elapsed: 100, reduceMotion: false) == text)
    #expect(TypedText.secondsPerCharacter == 0.028)
    #expect(!MotionPolicy(reduceMotion: true).pointerFlies)
    #expect(MotionPolicy(reduceMotion: false).pointerFlies)
  }

  @Test("ONBOARDING: theFlowKeepsWhatWasTyped (Never watch text survives Back and Continue)")
  func keepsTyped() {
    var f = OnboardingFlow()
    f.run(M304Path.toWhatLeaves + [.startSending(noticeVersion: "1"), .skip, .skip, .skip])
    #expect(f.screen == .rhythm)
    f.perform(.neverWatchText("Slack, mail.google.com"), now: M304Clock.now)
    f.perform(.back, now: M304Clock.now)
    #expect(f.screen == .drains)
    f.perform(.skip, now: M304Clock.now)
    #expect(f.screen == .rhythm)
    #expect(f.state.neverWatchText == "Slack, mail.google.com")
    #expect(OnboardingCopy.neverWatchLabel.lowercased().contains("never watch"))
  }

  @Test("ONBOARDING: every screen has one primary action and unique accessibility identifiers")
  func oneprimaryEach() {
    let s = OnboardingState()
    var ids = Set<String>()
    for screen in OnboardingScreen.allCases {
      let spec = OnboardingCopy.spec(for: screen, state: s)
      #expect(!spec.primaryTitle.isEmpty, "screen \(screen.rawValue)")
      #expect(!spec.headline.isEmpty, "screen \(screen.rawValue)")
      for id in [A11yID.primary(screen), A11yID.secondary(screen), A11yID.skip(screen), A11yID.screen(screen)] {
        #expect(!ids.contains(id), "duplicate \(id)")
        ids.insert(id)
      }
    }
    #expect(A11yID.primary(.permissions) == "onboarding.2.primary")
    #expect(OnboardingCopy.spec(for: .whatLeaves, state: s).primaryTitle == "Start sending")
    #expect(OnboardingCopy.spec(for: .whatLeaves, state: s).secondaryTitle == "Keep it on this Mac")
    #expect(OnboardingCopy.spec(for: .signIn, state: s).primaryTitle == "Continue in your browser")
    #expect(OnboardingCopy.spec(for: .signIn, state: s).secondaryTitle == "Not now")
    #expect(OnboardingCopy.spec(for: .whatItWatches, state: s).primaryTitle == "Get started")
    #expect(OnboardingCopy.spec(for: .done, state: s).primaryTitle == "Open today")
  }

  @Test("ONBOARDING: connect two apps reads Continue without connecting when none, and a connected tile ticks")
  @MainActor func connectApps() async {
    var s = OnboardingState()
    #expect(OnboardingCopy.spec(for: .connectApps, state: s).primaryTitle == "Continue without connecting")
    s.connectedApps = [ConnectedApp(id: "slack", account: "sample account")]
    #expect(OnboardingCopy.spec(for: .connectApps, state: s).primaryTitle == "Continue")
    #expect(ConnectionCatalog.launch.count >= 6)
    #expect(ConnectionCatalog.launch.allSatisfy { $0.pathLine == "Connects directly" || $0.pathLine == "Connects through Composio" })
    let fakes = M304Services()
    let model = fakes.model()
    for a in M304Path.toWhatLeaves { await model.perform(a) }
    await model.perform(.startSending(noticeVersion: "1"))
    for _ in 0..<4 { await model.perform(.skip) }
    #expect(model.flow.screen == .connectApps)
    await model.connect(appID: "gmail")
    #expect(fakes.connections.asked == ["gmail"])
    #expect(model.flow.state.connectedApps.map(\.id) == ["gmail"])
    fakes.connections.next = .cancelled
    await model.connect(appID: "notion")
    #expect(model.flow.state.connectedApps.map(\.id) == ["gmail"])
    #expect(model.connectMessage == "No problem. You can connect later.")
  }

  @Test("ONBOARDING: recordings are offered only after Start sending")
  func recordingsOnlyAfterConsent() {
    var withConsent = OnboardingFlow()
    withConsent.run(M304Path.toWhatLeaves + [.startSending(noticeVersion: "1"), .skip, .skip, .skip, .skip, .skip])
    #expect(withConsent.screen == .recordings)
    var s = OnboardingState()
    s.signedIn = true
    var noConsent = OnboardingFlow(state: s)
    noConsent.jump(to: .connectApps)
    noConsent.perform(.skip, now: M304Clock.now)
    #expect(noConsent.screen == .handsOn)
    #expect(!OnboardingFlow.isOffered(.recordings, state: s))
  }
}
