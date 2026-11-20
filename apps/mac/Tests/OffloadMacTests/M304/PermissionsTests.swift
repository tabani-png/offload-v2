import Foundation
import Testing
@testable import OffloadMac

// Screen 2 (ONBOARDING section 4). Ported from PR #44 (app/Sources/Core/Recordings.swift ScreenPermissionGate,
// Onboarding.swift update(_:)/justGranted) and clicky (WindowPositionManager.swift, CompanionManager.swift, MIT).
// A fake probe stands in for TCC, so nothing here prompts or opens System Settings.

extension M304 {
  @Test("PERMS: promptOnceThenSettings")
  @MainActor func promptOnceThenSettings() {
    #expect(ScreenPermissionGate.destination(hasPermissionNow: true, hasAttemptedSystemPrompt: false) == .alreadyGranted)
    #expect(ScreenPermissionGate.destination(hasPermissionNow: false, hasAttemptedSystemPrompt: false) == .systemPrompt)
    #expect(ScreenPermissionGate.destination(hasPermissionNow: false, hasAttemptedSystemPrompt: true) == .systemSettings)
    let probe = FakePermissionProbe()
    let model = PermissionsModel(probe: probe, screenRecordingConfirmed: false)
    model.tick()
    model.openSettings(for: .screenRecording)
    model.openSettings(for: .screenRecording)
    model.openSettings(for: .screenRecording)
    #expect(probe.screenCaptureRequests == 1)
    #expect(probe.opened.count == 2)
    #expect(probe.opened.allSatisfy { $0.absoluteString.hasSuffix("Privacy_ScreenCapture") })
    model.openSettings(for: .accessibility)
    model.openSettings(for: .accessibility)
    #expect(probe.accessibilityPrompts == 1)
    #expect(probe.opened.last?.absoluteString.hasSuffix("Privacy_Accessibility") == true)
    // Already on: nothing is asked or opened.
    probe.accessibility = true
    model.tick()
    let before = probe.opened.count
    model.openSettings(for: .accessibility)
    #expect(probe.opened.count == before)
    #expect(probe.accessibilityPrompts == 1)
  }

  @Test("PERMS: aConfirmedGrantSurvivesAPreflightFalseNegative")
  func confirmedGrantSurvives() {
    #expect(ScreenPermissionGate.treatAsGranted(now: false, previouslyConfirmed: true))
    #expect(ScreenPermissionGate.treatAsGranted(now: true, previouslyConfirmed: false))
    #expect(!ScreenPermissionGate.treatAsGranted(now: false, previouslyConfirmed: false))
    var t = PermissionTicker()
    t.apply(accessibility: false, screenPreflight: false)
    t.apply(accessibility: false, screenPreflight: true)
    #expect(t.isGranted(.screenRecording))
    #expect(t.screenRecordingConfirmed)
    t.apply(accessibility: false, screenPreflight: false)  // one false preflight
    #expect(t.isGranted(.screenRecording))
    // The confirmed grant is kept across launches through the saved state.
    var f = OnboardingFlow()
    f.run([.next, .next, .permissionsRead(accessibility: false, screenRecording: true)])
    #expect(f.state.screenRecordingConfirmed)
    let next = PermissionTicker(screenRecordingConfirmed: f.state.screenRecordingConfirmed)
    var n = next
    n.apply(accessibility: false, screenPreflight: false)
    #expect(n.isGranted(.screenRecording))
  }

  @Test("PERMS: settingsLinksArePrivacyPanes for macOS 14, 15 and 26, with the Privacy and Security root as fallback")
  func settingsLinks() {
    for major in [14, 15, 26] {
      #expect(PrivacyPane.isKnown(macOSMajor: major))
      #expect(PrivacyPane.url(for: .screenRecording, macOSMajor: major).absoluteString.hasSuffix("Privacy_ScreenCapture"))
      #expect(PrivacyPane.url(for: .accessibility, macOSMajor: major).absoluteString.hasSuffix("Privacy_Accessibility"))
      #expect(PrivacyPane.url(for: .screenRecording, macOSMajor: major).scheme == "x-apple.systempreferences")
      #expect(PrivacyPane.fallbackHint(for: .screenRecording, macOSMajor: major) == nil)
    }
    #expect(!PrivacyPane.isKnown(macOSMajor: 27))
    let root = PrivacyPane.url(for: .screenRecording, macOSMajor: 27).absoluteString
    #expect(root.hasPrefix("x-apple.systempreferences:"))
    #expect(!root.contains("Privacy_"))
    #expect(PrivacyPane.fallbackHint(for: .screenRecording, macOSMajor: 27) == "Choose Screen Recording, then turn on Offload.")
    #expect(PrivacyPane.fallbackHint(for: .accessibility, macOSMajor: 27) == "Choose Accessibility, then turn on Offload.")
  }

  @Test("PERMS: rows are checked every 1.5 s and tick only on a change seen while the screen is open")
  @MainActor func liveTicks() {
    #expect(PermissionTicker.interval == 1.5)
    var t = PermissionTicker()
    let first = t.apply(accessibility: true, screenPreflight: false)
    #expect(first.isEmpty)  // the first read is not "turning on"
    #expect(t.isGranted(.accessibility))
    let second = t.apply(accessibility: true, screenPreflight: true)
    #expect(second == [.screenRecording])
    #expect(t.justGranted == [.screenRecording])
    // The model polls the probe and publishes the ticks.
    let probe = FakePermissionProbe()
    let model = PermissionsModel(probe: probe, screenRecordingConfirmed: false)
    model.tick()
    #expect(!model.ticker.isGranted(.accessibility))
    probe.accessibility = true
    model.tick()
    #expect(model.ticker.justGranted == [.accessibility])
    #expect(model.rowStatus(.accessibility) == "on")
    #expect(model.rowStatus(.screenRecording) == "Open Settings")
    #expect(OnboardingCopy.permissionsCaption == "checks every 1.5 s · ticks the moment you flip it · you can continue with any missing")
  }

  @Test("PERMS: Show Offload in Finder only when a row is missing and Offload is not in the Settings list")
  @MainActor func showInFinder() {
    var t = PermissionTicker()
    t.apply(accessibility: false, screenPreflight: false)
    #expect(t.showInFinder(listedInSettings: []))
    #expect(!t.showInFinder(listedInSettings: [.accessibility, .screenRecording]))
    t.apply(accessibility: true, screenPreflight: true)
    #expect(!t.showInFinder(listedInSettings: []))
    let probe = FakePermissionProbe()
    let model = PermissionsModel(probe: probe, screenRecordingConfirmed: false)
    model.tick()
    #expect(model.showInFinder)
    model.openSettings(for: .accessibility)
    model.openSettings(for: .screenRecording)
    #expect(!model.showInFinder)  // asking once puts Offload in both lists
    model.revealInFinder()
    #expect(probe.finderReveals == 1)
    #expect(OnboardingCopy.showInFinder == "Show Offload in Finder")
  }

  @Test("PERMS: a Screen Recording grant seen while open asks to quit and reopen")
  @MainActor func quitAndReopen() {
    var t = PermissionTicker()
    t.apply(accessibility: true, screenPreflight: false)
    #expect(!t.needsRelaunch)
    t.apply(accessibility: true, screenPreflight: true)
    #expect(t.needsRelaunch)
    var already = PermissionTicker()
    already.apply(accessibility: true, screenPreflight: true)  // granted before this launch: no relaunch
    #expect(!already.needsRelaunch)
    #expect(OnboardingCopy.quitAndReopen == "Quit and reopen Offload")
  }

  @Test("PERMS: control names follow the running macOS version")
  func controlNames() {
    #expect(PrivacyPane.controlName(for: .screenRecording, macOSMajor: 14) == "Screen Recording")
    #expect(PrivacyPane.controlName(for: .screenRecording, macOSMajor: 15) == "Screen & System Audio Recording")
    #expect(PrivacyPane.controlName(for: .screenRecording, macOSMajor: 26) == "Screen & System Audio Recording")
    #expect(PrivacyPane.controlName(for: .accessibility, macOSMajor: 26) == "Accessibility")
    let rows = PermissionRow.rows(macOSMajor: 14)
    #expect(rows.map(\.kind) == [.accessibility, .screenRecording])
    #expect(rows[1].title == "Screen Recording")
    #expect(rows[0].tag == "needed for good results")
    #expect(rows[1].tag == "recommended")
    #expect(PermissionRow.rows(macOSMajor: 15)[1].title == "Screen & System Audio Recording")
  }
}
