import Foundation
import Testing
@testable import OffloadMac

// Tests added for review 1 (logs/m3-04-mac-onboarding.review1.md): behaviours that had no test, and the fixes for
// findings 3, 6 to 12, 14, 15 and 17. Written before the fixes.

extension M304 {
  // MARK: Finding 3: Never watch on screen 9

  @Test("NEVERWATCH: an app name that cannot be found keeps screen 9 open and says which one")
  @MainActor func unresolvedStays() async {
    let fakes = M304Services()
    let model = fakes.model()
    for a in M304Path.toWhatLeaves { await model.perform(a) }
    await model.perform(.startSending(noticeVersion: "1"))
    for _ in 0..<3 { await model.perform(.skip) }
    #expect(model.flow.screen == .rhythm)
    await model.perform(.neverWatchText("Slack, Nope App"))
    await model.leaveRhythm(answer: Rhythm()) { $0 == "Slack" ? "com.tinyspeck.slackmacgap" : nil }
    #expect(model.flow.screen == .rhythm)
    #expect(model.notice?.contains("Nope App") == true)
    #expect(fakes.neverWatch.currentExclusions().contains(Exclusion(kind: .bundleID, value: "com.tinyspeck.slackmacgap")))
    #expect(fakes.profile.patches.isEmpty)
    #expect(model.flow.state.neverWatchText == "Nope App")
  }

  @Test("NEVERWATCH: Skip on screen 9 still applies the typed entries and writes no profile field")
  @MainActor func skipApplies() async {
    let fakes = M304Services()
    let model = fakes.model()
    for a in M304Path.toWhatLeaves { await model.perform(a) }
    await model.perform(.startSending(noticeVersion: "1"))
    for _ in 0..<3 { await model.perform(.skip) }
    await model.perform(.neverWatchText("example.org"))
    await model.leaveRhythm(answer: nil) { _ in nil }
    #expect(model.flow.screen == .connectApps)
    #expect(fakes.neverWatch.currentExclusions().contains(Exclusion(kind: .host, value: "example.org")))
    #expect(fakes.profile.patches.isEmpty)
    #expect(model.flow.state.neverWatchText == "")
  }

  @Test("NEVERWATCH: an entry the person added can be listed and removed again")
  @MainActor func removeEntry() async {
    let fakes = M304Services()
    let model = fakes.model()
    let host = Exclusion(kind: .host, value: "example.org")
    await model.perform(.neverWatch(add: [host]))
    #expect(model.flow.state.neverWatch == [host])
    await model.perform(.neverWatchRemove(host))
    #expect(model.flow.state.neverWatch.isEmpty)
    #expect(!fakes.neverWatch.currentExclusions().contains(host))
  }

  // MARK: Finding 7: Never watch without sign-in

  @Test("NEVERWATCH: the menu bar offers Don't watch for the app in front, not for Offload or an app already excluded")
  func menuDontWatch() {
    let item = MenuNeverWatch.item(frontmostBundleID: "com.tinyspeck.slackmacgap", frontmostName: "Slack",
                                   ownBundleID: "ai.offload.mac.dev", current: [])
    #expect(item?.title == "Don't watch Slack")
    #expect(item?.exclusion == Exclusion(kind: .bundleID, value: "com.tinyspeck.slackmacgap"))
    #expect(MenuNeverWatch.item(frontmostBundleID: "ai.offload.mac.dev", frontmostName: "Offload",
                                ownBundleID: "ai.offload.mac.dev", current: []) == nil)
    #expect(MenuNeverWatch.item(frontmostBundleID: "com.tinyspeck.slackmacgap", frontmostName: "Slack", ownBundleID: nil,
                                current: [Exclusion(kind: .bundleID, value: "com.tinyspeck.slackmacgap")]) == nil)
    #expect(MenuNeverWatch.item(frontmostBundleID: nil, frontmostName: "Slack", ownBundleID: nil, current: []) == nil)
    #expect(OnboardingCopy.menuNeverWatchMore == "Never watch an app or site…")
  }

  @Test("NEVERWATCH: in Local mode Never watch works from the menu bar and applies only on this Mac")
  @MainActor func localModeNeverWatch() async {
    let fakes = M304Services()
    let model = fakes.model()
    for a in Array(M304Path.toWhatLeaves.prefix(5)) + [.notNow, .next] { await model.perform(a) }
    #expect(model.flow.state.completed && model.flow.state.mode == .local)
    let app = fakes.app()
    #expect(app.route == .today)
    let spotify = Exclusion(kind: .bundleID, value: "com.spotify.client")
    await app.dontWatch(spotify)
    #expect(fakes.neverWatch.currentExclusions().contains(spotify))
    #expect(fakes.exclusions.uploads.isEmpty)
    app.showNeverWatch()
    #expect(app.showingNeverWatch)
  }

  // MARK: Finding 4: behaviours without a test

  @Test("ONBOARDING: a failed consent call starts no uploader, returns to screen 5 and says so")
  @MainActor func consentFailure() async {
    let fakes = M304Services()
    fakes.consent.fails = true
    let model = fakes.model()
    for a in M304Path.toWhatLeaves { await model.perform(a) }
    await model.perform(.startSending(noticeVersion: "1"))
    #expect(fakes.uploader.starts == 0)
    #expect(model.flow.screen == .whatLeaves)
    #expect(!model.flow.state.uploadConsent)
    #expect(!model.flow.state.reconsentPending)
    #expect(model.notice == OnboardingCopy.consentFailed)
  }

  @Test("SHELL: capture starts again at launch after the Screen Recording relaunch, and not before screen 2")
  @MainActor func captureAtLaunch() async {
    let fresh = M304Services()
    _ = fresh.app()
    #expect(fresh.capture.starts == 0)
    let fakes = M304Services()
    let model = fakes.model()
    for a: OnboardingAction in [.next, .next, .permissionsRead(accessibility: true, screenRecording: true), .quitAndReopen] {
      await model.perform(a)
    }
    let relaunched = fakes.app()
    #expect(fakes.capture.starts == 1)
    #expect(relaunched.route == .onboarding(.lastTenMinutes))
  }

  @Test("SHELL: --onboarding-screen is saved, so a relaunch without the flag resumes there")
  @MainActor func jumpSaved() {
    let fakes = M304Services()
    let app = fakes.app(options: LaunchOptions(forceOnboarding: true, startScreen: .rhythm))
    #expect(app.route == .onboarding(.rhythm))
    #expect(fakes.store.load()?.screen == .rhythm)
    #expect(fakes.app().route == .onboarding(.rhythm))
  }

  @Test("SHELL: Today banners route to sign-in or Start sending, and a dismissed banner stays dismissed after relaunch")
  @MainActor func bannersRouteAndPersist() async throws {
    let fakes = M304Services()
    let model = fakes.model()
    for a in Array(M304Path.toWhatLeaves.prefix(5)) + [.notNow, .next] { await model.perform(a) }
    let app = fakes.app()
    let local = try #require(app.today.banners.first)
    #expect(local.id == TodayBanner.localID)
    app.tapBanner(local)
    #expect(app.route == .onboarding(.signIn))
    let again = fakes.app()
    again.showToday()
    again.dismissBanner(local)
    #expect(again.today.banners.isEmpty)
    #expect(fakes.app().today.banners.isEmpty)
  }

  @Test("SHELL: Start fresh begins setup again and keeps the Never watch entries")
  @MainActor func startFreshKeeps() async {
    let fakes = M304Services()
    let model = fakes.model()
    let host = Exclusion(kind: .host, value: "example.org")
    for a in Array(M304Path.toWhatLeaves.prefix(5)) + [.notNow, .neverWatch(add: [host]), .next] { await model.perform(a) }
    let app = fakes.app()
    app.startFresh()
    #expect(app.route == .onboarding(.install))
    #expect(fakes.store.load()?.completed == false)
    #expect(fakes.store.load()?.neverWatch == [host])
    #expect(fakes.neverWatch.currentExclusions().contains(host))
  }

  // MARK: Finding 11: re-consent

  @Test("SHELL: a new notice version opens screen 5 and pauses the uploader at launch")
  @MainActor func reconsentAtLaunch() async {
    let fakes = M304Services()
    let model = fakes.model()
    for a in M304Path.toWhatLeaves + [.startSending(noticeVersion: "1"), .skip, .skip, .skip, .skip, .skip, .skip, .skip, .next] {
      await model.perform(a)
    }
    #expect(model.flow.state.completed)
    let same = fakes.app(currentNoticeVersion: "1")
    #expect(same.route == .today)
    #expect(fakes.uploader.pauses == 0)
    let changed = fakes.app(currentNoticeVersion: "2")
    #expect(changed.route == .onboarding(.whatLeaves))
    #expect(fakes.uploader.pauses == 1)
    #expect(fakes.store.load()?.uploadConsent == false)
    #expect(fakes.store.load()?.reconsentPending == true)
  }

  @Test("ONBOARDING: re-consent keeps the first setup date and marks the notice new until the person chooses")
  func reconsentKeepsDate() {
    var f = OnboardingFlow()
    f.run(M304Path.toWhatLeaves + [.startSending(noticeVersion: "1"), .skip, .skip, .skip, .skip, .skip, .skip, .skip])
    f.perform(.next, now: M304Clock.now)
    let first = f.state.setupCompletedAt
    #expect(first == M304Clock.now)
    f.perform(.reconsentNeeded, now: M304Clock.now)
    #expect(f.state.reconsentPending)
    #expect(OnboardingCopy.spec(for: .whatLeaves, state: f.state).badge == "new")
    f.perform(.startSending(noticeVersion: "2"), now: M304Clock.now)
    #expect(!f.state.reconsentPending)
    #expect(OnboardingCopy.spec(for: .whatLeaves, state: f.state).badge == nil)
    f.perform(.next, now: M304Clock.now.addingTimeInterval(86_400))
    #expect(f.state.setupCompletedAt == first)
  }

  // MARK: Finding 10: profile writes need consent

  @Test("ONBOARDING: answers given before Start sending stay on this Mac and send no profile field")
  func answersNeedConsent() {
    var s = OnboardingState()
    s.signedIn = true
    var f = OnboardingFlow(state: s)
    f.jump(to: .role)
    let effects = f.perform(.answer(.role("Founder")), now: M304Clock.now)
    #expect(effects.isEmpty)
    #expect(f.state.profile.role == "Founder")
    #expect(f.screen == .goals)
  }

  // MARK: Finding 6: honest about capture

  @Test("SHELL: the menu bar and screen 13 say Offload is not watching yet when capture is not running")
  @MainActor func honestCapture() {
    #expect(MenuBarStatus.line(isCapturing: false, waiting: 0) == "not watching yet.")
    #expect(MenuBarStatus.line(isCapturing: true, waiting: 0) == BuddyMood.watching.line)
    #expect(MenuBarStatus.line(isCapturing: false, waiting: 2) == BuddyMood.foundSomething.line)
    var s = OnboardingState()
    s.completed = true
    #expect(OnboardingCopy.doneBody(state: s, capturing: false) == OnboardingCopy.localNotCapturingBody)
    #expect(!OnboardingCopy.localNotCapturingBody.lowercased().contains("is watching"))
    #expect(OnboardingCopy.doneBody(state: s, capturing: true) == OnboardingCopy.localBody)
    #expect(!NoCapture().isRunning)
  }

  // MARK: Finding 8: Move and reopen

  @Test("SHELL: Move and reopen copies beside the old copy, then replaces it, clears quarantine and opens it; a failure leaves the old copy")
  @MainActor func moveAndReopen() {
    let src = URL(fileURLWithPath: "/Volumes/Offload/Offload.app")
    let apps = URL(fileURLWithPath: "/Applications")
    let tmp = "/Applications/.Offload.app.moving"
    let dst = "/Applications/Offload.app"
    let fresh = FakeFileOps()
    #expect(AppMover.move(source: src, applications: apps, ops: fresh) == .opened(path: dst))
    #expect(fresh.log == ["copy \(src.path) \(tmp)", "move \(tmp) \(dst)", "unquarantine \(dst)", "open \(dst)"])
    let older = FakeFileOps()
    older.existing = [dst]
    #expect(AppMover.move(source: src, applications: apps, ops: older) == .opened(path: dst))
    #expect(older.log == ["copy \(src.path) \(tmp)", "replace \(dst) \(tmp)", "unquarantine \(dst)", "open \(dst)"])
    // A failed copy changes nothing: the old copy stays in Applications.
    let copyFails = FakeFileOps()
    copyFails.existing = [dst]
    copyFails.copyFails = true
    #expect(AppMover.move(source: src, applications: apps, ops: copyFails) == .failed(OnboardingCopy.moveFailed))
    #expect(copyFails.log.isEmpty)
    #expect(copyFails.existing == [dst])
    // A failed replace removes the half-done copy and keeps the old one.
    let replaceFails = FakeFileOps()
    replaceFails.existing = [dst]
    replaceFails.replaceFails = true
    #expect(AppMover.move(source: src, applications: apps, ops: replaceFails) == .failed(OnboardingCopy.moveFailed))
    #expect(replaceFails.log == ["copy \(src.path) \(tmp)", "remove \(tmp)"])
    #expect(replaceFails.existing == [dst])
  }

  // MARK: Finding 9: a confirmed grant is not forever

  @Test("PERMS: a confirmed grant is dropped after three false checks in a row or a failed capture, and the loss allows one more notice")
  func confirmedGrantExpires() {
    #expect(PermissionTicker.falseReadsBeforeLoss == 3)
    var t = PermissionTicker(screenRecordingConfirmed: true)
    t.apply(accessibility: true, screenPreflight: false)
    t.apply(accessibility: true, screenPreflight: false)
    #expect(t.isGranted(.screenRecording))
    t.apply(accessibility: true, screenPreflight: false)
    #expect(!t.isGranted(.screenRecording))
    #expect(!t.screenRecordingConfirmed)
    var u = PermissionTicker()
    u.apply(accessibility: true, screenPreflight: true)
    u.screenCaptureFailed()
    u.apply(accessibility: true, screenPreflight: false)
    #expect(!u.isGranted(.screenRecording))
    // The flow records the loss: one more notification is allowed.
    var f = OnboardingFlow()
    f.run([.next, .next, .permissionsRead(accessibility: true, screenRecording: true)])
    var reask = f.state.reask
    let first = reask.notify(.screenRecording)
    #expect(first)
    f.setReask(reask)
    f.perform(.permissionsRead(accessibility: true, screenRecording: false), now: M304Clock.now)
    #expect(!f.state.screenRecording && !f.state.screenRecordingConfirmed)
    var after = f.state.reask
    let again = after.notify(.screenRecording)
    #expect(again)
    #expect(OnboardingCopy.permissionOn("Accessibility") == "Accessibility is on.")
  }

  // MARK: Finding 12: screen 3

  @Test("NOW: under one full active minute the line still says nothing seen yet, and the remark waits for the pointer")
  func underAMinute() {
    let now = NowFixture.now
    let short = LocalNowSummary.compute(
      events: [LocalEvent(id: "a", ts: now - 30_000, kind: "focus", app: "com.apple.Notes", appName: "Notes")], now: now, minutes: 10)
    #expect(short.line == "Nothing seen yet. Keep working for a minute.")
    #expect(short.remark == "")
    var screen = LastTenMinutesState(openedAt: M304Clock.now)
    _ = screen.received(short)
    #expect(!screen.showsRemark)
    #expect(!screen.seesSomething)
    _ = screen.received(LocalNowSummary.compute(events: NowFixture.tenMinutes(), now: now, minutes: 10))
    #expect(screen.showsRemark)
  }

  // MARK: Finding 14: screen 5

  @Test("ONBOARDING: screen 5's batch list uses the local ledger's 7 days, not the cloud text TTL, and links the privacy details")
  func ledgerDays() {
    let c = RetentionConfig(values: ["OFFLOAD_TEXT_TTL_DAYS": "5"])
    #expect(c.ledgerDays == 7)
    let facts = OnboardingCopy.whatLeavesFacts(c)
    #expect(facts.contains { $0.contains("in the last 7 days") })
    #expect(!facts.contains { $0.contains("in the last 5 days") })
    #expect(PrivacyLinks.details.scheme == "https")
    #expect(PrivacyLinks.details.absoluteString.hasSuffix("SECURITY_PRIVACY.md"))
  }

  // MARK: Finding 15: screen 4

  @Test("ONBOARDING: while waiting for the browser, Open the page again asks the account service again")
  @MainActor func reopenPage() {
    let fakes = M304Services()
    let model = fakes.model()
    model.reopenSignInPage()
    #expect(fakes.account.reopens == 1)
    #expect(OnboardingCopy.signInOpenAgain == "Open the page again")
  }

  // MARK: Finding 17: Show in Finder after a relaunch

  @Test("PERMS: after a relaunch Show in Finder stays hidden for rows Offload was already added to")
  @MainActor func listedSurvivesRelaunch() {
    let probe = FakePermissionProbe()
    let first = PermissionsModel(probe: probe, screenRecordingConfirmed: false)
    first.tick()
    #expect(first.openSettings(for: .accessibility) == .systemPrompt)
    #expect(first.openSettings(for: .accessibility) == .systemSettings)
    var f = OnboardingFlow()
    f.perform(.promptedInSettings(.accessibility), now: M304Clock.now)
    f.perform(.promptedInSettings(.screenRecording), now: M304Clock.now)
    #expect(f.state.listedInSettings == [.accessibility, .screenRecording])
    let relaunched = PermissionsModel(probe: FakePermissionProbe(), screenRecordingConfirmed: false,
                                      listedInSettings: f.state.listedInSettings)
    relaunched.tick()
    #expect(!relaunched.showInFinder)
    let partly = PermissionsModel(probe: FakePermissionProbe(), screenRecordingConfirmed: false, listedInSettings: [.accessibility])
    partly.tick()
    #expect(partly.showInFinder)
  }
}
