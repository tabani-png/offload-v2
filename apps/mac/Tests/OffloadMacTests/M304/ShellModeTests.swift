import Foundation
import Testing
@testable import OffloadMac

// The app shell's launch decisions (ONBOARDING sections 4, 11 and 13 test hooks), the product modes (10.1) and the
// limits on re-asking (10.3).

extension M304 {
  @Test("SHELL: first run opens onboarding; a finished setup opens Today")
  func firstRunThenToday() {
    let app = "/Applications/Offload.app"
    #expect(LaunchRoute.decide(options: LaunchOptions(), state: OnboardingState(), bundlePath: app,
                               bufferReadable: true, currentNoticeVersion: nil) == .onboarding(.install))
    var done = OnboardingState()
    done.completed = true
    done.screen = .done
    #expect(LaunchRoute.decide(options: LaunchOptions(), state: done, bundlePath: app,
                               bufferReadable: true, currentNoticeVersion: nil) == .today)
  }

  @Test("SHELL: --onboarding and --onboarding-screen n force the flow at that screen")
  func launchFlags() {
    #expect(LaunchOptions.parse(arguments: ["Offload"]) == LaunchOptions())
    let forced = LaunchOptions.parse(arguments: ["Offload", "--onboarding"])
    #expect(forced.forceOnboarding && forced.startScreen == nil)
    let at = LaunchOptions.parse(arguments: ["Offload", "--onboarding-screen", "9"])
    #expect(at.forceOnboarding && at.startScreen == .rhythm)
    #expect(LaunchOptions.parse(arguments: ["Offload", "--onboarding-screen", "99"]).startScreen == nil)
    #expect(LaunchOptions.parse(arguments: ["Offload", "--onboarding-screen"]).startScreen == nil)
    var done = OnboardingState()
    done.completed = true
    #expect(LaunchRoute.decide(options: forced, state: done, bundlePath: "/Applications/Offload.app",
                               bufferReadable: true, currentNoticeVersion: nil) == .onboarding(.install))
    #expect(LaunchRoute.decide(options: at, state: done, bundlePath: "/Applications/Offload.app",
                               bufferReadable: true, currentNoticeVersion: nil) == .onboarding(.rhythm))
  }

  @Test("SHELL: a translocated or disk-image path asks to move to Applications first")
  func moveToApplications() {
    #expect(InstallLocation.needsMove(bundlePath: "/private/var/folders/xy/T/AppTranslocation/1234/d/Offload.app"))
    #expect(InstallLocation.needsMove(bundlePath: "/Volumes/Offload/Offload.app"))
    #expect(!InstallLocation.needsMove(bundlePath: "/Applications/Offload.app"))
    #expect(!InstallLocation.needsMove(bundlePath: "/Users/someone/Applications/Offload.app"))
    // A development build from `swift build` is not a bundle: no sheet.
    #expect(!InstallLocation.needsMove(bundlePath: "/Users/someone/src/apps/mac/.build/debug"))
    #expect(LaunchRoute.decide(options: LaunchOptions(), state: OnboardingState(), bundlePath: "/Volumes/Offload/Offload.app",
                               bufferReadable: true, currentNoticeVersion: nil) == .moveToApplications)
    #expect(OnboardingCopy.moveTitle == "Move Offload to Applications")
    #expect(OnboardingCopy.movePrimary == "Move and reopen" && OnboardingCopy.moveSecondary == "Quit")
  }

  @Test("SHELL: a local buffer that cannot be opened offers Start fresh before anything else")
  func startFresh() {
    var done = OnboardingState()
    done.completed = true
    #expect(LaunchRoute.decide(options: LaunchOptions(), state: done, bundlePath: "/Applications/Offload.app",
                               bufferReadable: false, currentNoticeVersion: nil) == .startFresh)
    #expect(OnboardingCopy.startFreshBody == "Offload's saved data on this Mac can't be opened. Start fresh?")
    #expect(OnboardingCopy.startFreshPrimary == "Start fresh")
  }

  @Test("SHELL: Today with no data shows the honest empty state and no invented number")
  func todayEmpty() {
    var s = OnboardingState()
    s.completed = true
    s.signedIn = true
    s.uploadConsent = true
    s.accessibility = true
    s.screenRecording = true
    let t = TodayModel(state: s, now: M304Clock.now)
    #expect(t.title == "Today")
    #expect(t.emptyTitle == "Nothing to show yet.")
    #expect(t.emptyBody == "Offload needs a few ordinary workdays to see what repeats. Keep working.")
    for line in [t.emptyTitle, t.emptyBody] {
      #expect(line.rangeOfCharacter(from: .decimalDigits) == nil)
    }
    #expect(t.headline.blocks == [.headline])
    #expect(A11yID.todayEmpty == "today.empty")
    #expect(t.banners.isEmpty)
  }

  @Test("MODE: every row of the product modes table derives from sending, permissions and connections")
  func modesTable() {
    #expect(ProductMode.derive(sending: true, accessibility: true, screenRecording: true, appsConnected: true) == .full)
    #expect(ProductMode.derive(sending: true, accessibility: true, screenRecording: true, appsConnected: false) == .watching)
    #expect(ProductMode.derive(sending: true, accessibility: true, screenRecording: false, appsConnected: true) == .textOnly)
    #expect(ProductMode.derive(sending: true, accessibility: true, screenRecording: false, appsConnected: false) == .textOnly)
    #expect(ProductMode.derive(sending: true, accessibility: false, screenRecording: true, appsConnected: false) == .screenOnly)
    #expect(ProductMode.derive(sending: true, accessibility: false, screenRecording: false, appsConnected: true) == .connectedAppsOnly)
    #expect(ProductMode.derive(sending: true, accessibility: false, screenRecording: false, appsConnected: false) == .dormant)
    for ax in [true, false] {
      for sr in [true, false] {
        for apps in [true, false] {
          #expect(ProductMode.derive(sending: false, accessibility: ax, screenRecording: sr, appsConnected: apps) == .local)
        }
      }
    }
    #expect(ProductMode.allCases.map(\.displayName)
            == ["Full", "Watching", "Text only", "Screen only", "Connected apps only", "Dormant", "Local"])
    var s = OnboardingState()
    s.signedIn = true
    s.uploadConsent = true
    s.accessibility = true
    #expect(s.mode == .textOnly)
    let today = TodayModel(state: s, now: M304Clock.now)
    #expect(today.banners.contains { $0.text == "Screen reading is off" && $0.action == "Turn on" })
  }

  @Test("MODE: Local mode shows one banner: Sign in when signed out, Start sending when signed in")
  func localBanner() {
    var s = OnboardingState()
    s.completed = true
    let out = TodayModel(state: s, now: M304Clock.now).banners
    #expect(out.count == 1)
    #expect(out.first?.text == "Sign in to see your week and get fixes.")
    #expect(out.first?.action == "Sign in")
    s.signedIn = true
    let signedIn = TodayModel(state: s, now: M304Clock.now).banners
    #expect(signedIn.count == 1)
    #expect(signedIn.first?.action == "Start sending")
    #expect(signedIn.first?.id == TodayBanner.localID)
  }

  @Test("REASK: at most one notification per missing permission, and again only after a grant was lost")
  func oneNotification() {
    // #expect cannot call a mutating method on a local (its expansion captures the value immutably), so each answer
    // is taken first and checked after.
    var r = ReaskState()
    let firstAccessibility = r.notify(.accessibility)
    let secondAccessibility = r.notify(.accessibility)
    let firstScreen = r.notify(.screenRecording)
    let secondScreen = r.notify(.screenRecording)
    #expect(firstAccessibility)
    #expect(!secondAccessibility)
    #expect(firstScreen)
    #expect(!secondScreen)
    r.grantLost(.accessibility)
    let afterLoss = r.notify(.accessibility)
    let afterLossAgain = r.notify(.accessibility)
    #expect(afterLoss)
    #expect(!afterLossAgain)
  }

  @Test("REASK: a dismissed banner stays dismissed for 30 days")
  func bannerThirtyDays() {
    var s = OnboardingState()
    s.completed = true
    s.reask.dismiss(TodayBanner.localID, at: M304Clock.now)
    #expect(!s.reask.bannerVisible(TodayBanner.localID, now: M304Clock.now.addingTimeInterval(29 * 86_400)))
    #expect(s.reask.bannerVisible(TodayBanner.localID, now: M304Clock.now.addingTimeInterval(30 * 86_400)))
    #expect(TodayModel(state: s, now: M304Clock.now.addingTimeInterval(86_400)).banners.isEmpty)
    #expect(TodayModel(state: s, now: M304Clock.now.addingTimeInterval(31 * 86_400)).banners.count == 1)
  }

  @Test("REASK: Dormant reminders stop after the second, and no modal re-asks after setup")
  func dormantAndModal() {
    var r = ReaskState()
    let reminders = (0..<4).map { _ in r.dormantReminder() }
    #expect(reminders == [true, true, false, false])
    #expect(ReaskPolicy.mayShowModal(setupCompleted: false))
    #expect(!ReaskPolicy.mayShowModal(setupCompleted: true))
    #expect(ReaskPolicy.bannerQuietDays == 30)
  }
}
