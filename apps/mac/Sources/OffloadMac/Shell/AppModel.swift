import AppKit
import SwiftUI

/// The app's root model: decides the launch route, owns the onboarding and permissions models, and switches to Today
/// when setup is done. Everything it calls is injected, so `OffloadMacApp` only wires the live pieces.
@MainActor
public final class AppModel: ObservableObject {
  @Published public private(set) var route: LaunchRoute
  @Published public private(set) var today: TodayModel
  public let onboarding: OnboardingModel
  public let permissions: PermissionsModel
  public let events: LocalEventSource
  public let sampleWeek: SampleWeekFlag
  public let neverWatch: NeverWatchStore

  public init(options: LaunchOptions, bundlePath: String, bufferReadable: Bool, store: OnboardingStore,
              services: OnboardingServices, probe: PermissionProbe, events: LocalEventSource, sampleWeek: SampleWeekFlag) {
    let onboarding = OnboardingModel(store: store, services: services)
    self.onboarding = onboarding
    self.permissions = PermissionsModel(probe: probe, screenRecordingConfirmed: onboarding.state.screenRecordingConfirmed)
    self.events = events
    self.sampleWeek = sampleWeek
    self.neverWatch = services.neverWatch
    let route = LaunchRoute.decide(options: options, state: onboarding.state, bundlePath: bundlePath,
                                   bufferReadable: bufferReadable, currentNoticeVersion: nil)
    self.route = route
    self.today = TodayModel(state: onboarding.state, now: Date())
    if case .onboarding(let screen) = route, options.forceOnboarding {
      onboarding.jump(to: screen)
    }
    // Capture resumes after a relaunch once screen 2 was resolved with a permission on.
    if onboarding.state.captureStarted { services.capture.start() }
    onboarding.onOpenToday = { [weak self] in self?.showToday() }
  }

  /// The app as shipped in this build: real permission checks; sign-in, upload, profile and connections are local
  /// stand-ins (their backends land in later slices); nothing is sent anywhere.
  public static func live(arguments: [String] = ProcessInfo.processInfo.arguments) -> AppModel {
    let sampleWeek = SampleWeekFlag()
    let services = OnboardingServices(
      account: UnavailableAccountService(), consent: LocalConsentService(), uploader: NoUploader(), capture: NoCapture(),
      profile: LocalProfileService(), neverWatch: NeverWatchStore(), exclusions: LocalExclusionService(),
      connections: UnavailableConnectionService(), loginItem: LiveLoginItem(), relauncher: LiveRelauncher(),
      sampleWeek: sampleWeek
    )
    return AppModel(
      options: LaunchOptions.parse(arguments: arguments), bundlePath: Bundle.main.bundlePath, bufferReadable: true,
      store: UserDefaultsOnboardingStore(), services: services, probe: LivePermissionProbe(), events: NoLocalEvents(),
      sampleWeek: sampleWeek
    )
  }

  public var isOnboarding: Bool {
    if case .onboarding = route { return true }
    return false
  }

  public func showToday() {
    today = TodayModel(state: onboarding.state, now: Date())
    route = .today
  }

  public func continueSetup() {
    route = .onboarding(onboarding.state.screen)
  }

  public func tapBanner(_ banner: TodayBanner) {
    switch banner.id {
    case TodayBanner.finishSettingUpID:
      continueSetup()
    case TodayBanner.localID:
      onboarding.jump(to: onboarding.state.signedIn ? .whatLeaves : .signIn)
      route = .onboarding(onboarding.state.screen)
    default:
      onboarding.jump(to: .permissions)
      route = .onboarding(.permissions)
    }
  }

  public func dismissBanner(_ banner: TodayBanner) {
    var s = onboarding.state
    s.reask.dismiss(banner.id, at: Date())
    // Saved through the flow so it survives relaunch.
    onboarding.saveReask(s.reask)
    today = TodayModel(state: onboarding.state, now: Date())
  }

  /// Row 11.6 "Start fresh": the unreadable buffer is the store's to delete (m3-02); here setup starts over.
  public func startFresh() {
    onboarding.reset()
    route = .onboarding(.install)
  }

  /// Screen 0 "Move and reopen": copies Offload into /Applications (or uses the copy already there) and opens it.
  public func moveToApplications() {
    let fm = FileManager.default
    let src = Bundle.main.bundleURL
    let dst = URL(fileURLWithPath: "/Applications").appendingPathComponent(src.lastPathComponent)
    do {
      if !fm.fileExists(atPath: dst.path) { try fm.copyItem(at: src, to: dst) }
    } catch {
      quit()
      return
    }
    let config = NSWorkspace.OpenConfiguration()
    config.createsNewApplicationInstance = true
    NSWorkspace.shared.openApplication(at: dst, configuration: config) { _, error in
      let ok = error == nil
      Task { @MainActor in
        if ok { NSApp.terminate(nil) }
      }
    }
  }

  public func quit() { NSApp.terminate(nil) }
}
