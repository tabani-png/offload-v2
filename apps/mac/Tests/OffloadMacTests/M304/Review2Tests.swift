import Combine
import Foundation
import Testing
@testable import OffloadMac

// Tests added for review 2 (logs/m3-04-mac-onboarding.review2.md), findings 2, 4 to 7, 9, 11 and 14. Written before
// the fixes.

extension M304 {
  /// A finished setup that is sending, with the given notice version, saved in `fakes.store`.
  @MainActor static func finishedSending(_ fakes: M304Services, version: String = "1") async {
    let model = fakes.model()
    for a in M304Path.toWhatLeaves + [.startSending(noticeVersion: version), .skip, .skip, .skip, .skip, .skip, .skip, .skip, .next] {
      await model.perform(a)
    }
  }

  // MARK: Finding 2: the uploader at launch

  @Test("SHELL: at launch the uploader starts for a consented person, stays paused when the notice changed, and never starts without consent")
  @MainActor func uploaderAtLaunch() async {
    let fakes = M304Services()
    await Self.finishedSending(fakes)
    let before = fakes.uploader.starts
    _ = fakes.app(currentNoticeVersion: "1")
    #expect(fakes.uploader.starts == before + 1)
    _ = fakes.app()  // version not known yet (no sign-in in this build): the consent on record stands
    #expect(fakes.uploader.starts == before + 2)
    _ = fakes.app(currentNoticeVersion: "2")
    #expect(fakes.uploader.starts == before + 2)
    #expect(fakes.uploader.pauses == 1)
    _ = fakes.app(currentNoticeVersion: "2")  // still not accepted: still not sending
    #expect(fakes.uploader.starts == before + 2)

    let local = M304Services()
    let model = local.model()
    for a in Array(M304Path.toWhatLeaves.prefix(5)) + [.notNow, .next] { await model.perform(a) }
    _ = local.app()
    #expect(local.uploader.starts == 0)
  }

  // MARK: Finding 4: macOS's own Quit & Reopen

  @Test("ONBOARDING: after macOS's own Quit & Reopen, a launch on screen 2 that finds Screen Recording on resumes at screen 3")
  @MainActor func macOSReopen() async {
    let fakes = M304Services()
    let model = fakes.model()
    for a: OnboardingAction in [.next, .next, .permissionsRead(accessibility: true, screenRecording: false)] { await model.perform(a) }
    #expect(model.flow.screen == .permissions)
    let stillOff = FakePermissionProbe()
    stillOff.accessibility = true
    #expect(fakes.app(probe: stillOff).route == .onboarding(.permissions))
    let granted = FakePermissionProbe()
    granted.accessibility = true
    granted.preflight = true
    let app = fakes.app(probe: granted)
    #expect(app.route == .onboarding(.lastTenMinutes))
    #expect(app.onboarding.state.showScreenReadingOn)
    #expect(app.onboarding.state.screenRecording)
    #expect(fakes.capture.starts == 1)
  }

  // MARK: Finding 5: permissions read at launch

  @Test("SHELL: permissions are read at launch, so Today's mode follows a revocation made while Offload was closed")
  @MainActor func launchRead() async {
    let fakes = M304Services()
    await Self.finishedSending(fakes)
    #expect(fakes.store.load()?.mode == .watching)
    let probe = FakePermissionProbe()
    probe.accessibility = false
    probe.preflight = true
    let app = fakes.app(probe: probe)
    #expect(app.onboarding.state.accessibility == false)
    #expect(app.today.mode == .screenOnly)
    #expect(app.today.banners.contains { $0.text == OnboardingCopy.windowDetailsOff })
    #expect(PermissionsModel.backgroundInterval == 5)
  }

  // MARK: Finding 6: "Turn on" from Today

  @Test("SHELL: Turn on in Today asks for the missing permission and stays on Today")
  @MainActor func turnOnFromToday() async throws {
    let fakes = M304Services()
    var s = OnboardingState()
    s.completed = true
    s.screen = .done
    s.signedIn = true
    s.uploadConsent = true
    s.consentedNoticeVersion = "1"
    s.accessibility = true
    fakes.store.save(s)
    let probe = FakePermissionProbe()
    probe.accessibility = true
    let app = fakes.app(probe: probe)
    #expect(app.today.mode == .textOnly)
    let banner = try #require(app.today.banners.first { $0.id == TodayBanner.modeID })
    app.tapBanner(banner)
    #expect(app.route == .today)
    #expect(probe.screenCaptureRequests == 1)
    app.tapBanner(banner)
    #expect(app.route == .today)
    #expect(probe.opened.last?.absoluteString.hasSuffix("Privacy_ScreenCapture") == true)
  }

  // MARK: Finding 7: the menu bar entry goes away once used

  @Test("NEVERWATCH: the menu bar Don't watch entry goes away once used, and the menu is told to redraw")
  @MainActor func menuEntryGoesAway() async throws {
    let fakes = M304Services()
    let app = fakes.app()
    app.noteFrontmost(bundleID: "com.spotify.client", name: "Spotify")
    let item = try #require(app.menuNeverWatchItem)
    #expect(item.title == "Don't watch Spotify")
    var redraws = 0
    let watcher = app.objectWillChange.sink { _ in redraws += 1 }
    await app.dontWatch(item.exclusion)
    #expect(app.menuNeverWatchItem == nil)
    #expect(redraws > 0)
    watcher.cancel()
  }

  // MARK: Finding 9: what was kept locally reaches the account after consent

  @Test("ONBOARDING: Start sending sends the Never watch entries and the answers given before, and nothing if consent fails")
  @MainActor func catchUpAfterConsent() async {
    let host = Exclusion(kind: .host, value: "example.org")
    var s = OnboardingState()
    s.signedIn = true
    s.screen = .whatLeaves
    s.neverWatch = [host]
    s.profile.role = "Founder"
    s.profile.goals = ["Less admin"]
    var f = OnboardingFlow(state: s)
    let effects = f.perform(.startSending(noticeVersion: "1"), now: M304Clock.now)
    #expect(effects == [.recordConsent(noticeVersion: "1"), .startUploader, .uploadExclusions([host]),
                        .patchProfile(ProfileUpdate(role: "Founder", goals: ["Less admin"]))])

    let fakes = M304Services()
    fakes.store.save(s)
    fakes.consent.fails = true
    let model = fakes.model()
    await model.perform(.startSending(noticeVersion: "1"))
    #expect(fakes.exclusions.uploads.isEmpty)
    #expect(fakes.profile.patches.isEmpty)
    #expect(fakes.uploader.starts == 0)

    let ok = M304Services()
    ok.store.save(s)
    let okModel = ok.model()
    await okModel.perform(.startSending(noticeVersion: "1"))
    #expect(ok.exclusions.uploads == [[host]])
    #expect(ok.profile.patches == [ProfileUpdate(role: "Founder", goals: ["Less admin"])])
  }

  // MARK: Finding 11: screen 11 records nothing that did not happen

  @Test("ONBOARDING: Import on screen 11 stays on the screen and records no import until import exists")
  @MainActor func importStays() async {
    let fakes = M304Services()
    let model = fakes.model()
    for a in M304Path.toWhatLeaves + [.startSending(noticeVersion: "1"), .skip, .skip, .skip, .skip, .skip] { await model.perform(a) }
    #expect(model.flow.screen == .recordings)
    await model.perform(.importRecordings)
    #expect(model.flow.screen == .recordings)
    #expect(!model.flow.state.recordingsImportStarted)
    #expect(model.notice == OnboardingCopy.recordingsNotReady)
    await model.perform(.skip)
    #expect(model.flow.screen == .handsOn)
  }

  // MARK: Finding 14: every label comes from the copy table

  @Test("COPY: button and picker labels come from the copy table, so the copy tests see them")
  func labelsInCopy() {
    #expect(OnboardingCopy.back == "Back")
    #expect(OnboardingCopy.on == "on")
    #expect(OnboardingCopy.rhythmEnd == "Until")
    #expect(OnboardingCopy.rhythmReviewTime == "Review time")
    let all = OnboardingCopy.allStrings
    for label in [OnboardingCopy.back, OnboardingCopy.on, OnboardingCopy.rhythmEnd, OnboardingCopy.rhythmReviewTime] {
      #expect(all.contains(label))
    }
  }
}
