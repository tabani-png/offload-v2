import AppKit
import SwiftUI

/// The app's root model: decides the launch route, owns the onboarding and permissions models, and switches to Today
/// when setup is done. Everything it calls is injected, so `OffloadMacApp` only wires the live pieces.
@MainActor
public final class AppModel: ObservableObject {
  @Published public private(set) var route: LaunchRoute
  @Published public private(set) var today: TodayModel
  /// The Never watch sheet (menu bar "Never watch an app or site…"), available in every mode.
  @Published public var showingNeverWatch = false
  /// The app in front other than Offload, for the menu bar's "Don't watch <app>".
  @Published public private(set) var frontmost: (bundleID: String, name: String)?
  /// Shown on the move sheet when copying to Applications failed.
  @Published public private(set) var moveError: String?
  public let onboarding: OnboardingModel
  public let permissions: PermissionsModel
  public let events: LocalEventSource
  public let sampleWeek: SampleWeekFlag
  public let neverWatch: NeverWatchStore

  private var frontmostObserver: NSObjectProtocol?

  /// `currentNoticeVersion` is the server's "What leaves your Mac" version from `GET /v1/me` (nil until sign-in
  /// exists, m1-04).
  public init(options: LaunchOptions, bundlePath: String, bufferReadable: Bool, store: OnboardingStore,
              services: OnboardingServices, probe: PermissionProbe, events: LocalEventSource, sampleWeek: SampleWeekFlag,
              currentNoticeVersion: String? = nil) {
    let onboarding = OnboardingModel(store: store, services: services)
    self.onboarding = onboarding
    self.permissions = PermissionsModel(probe: probe, screenRecordingConfirmed: onboarding.state.screenRecordingConfirmed,
                                        listedInSettings: onboarding.state.listedInSettings)
    self.events = events
    self.sampleWeek = sampleWeek
    self.neverWatch = services.neverWatch
    let route = LaunchRoute.decide(options: options, state: onboarding.state, bundlePath: bundlePath,
                                   bufferReadable: bufferReadable, currentNoticeVersion: currentNoticeVersion)
    self.route = route
    self.today = TodayModel(state: onboarding.state, now: Date())
    if case .onboarding(let screen) = route, options.forceOnboarding {
      onboarding.jump(to: screen)
    } else if route == .onboarding(.whatLeaves), onboarding.state.uploadConsent,
              let current = currentNoticeVersion, current != onboarding.state.consentedNoticeVersion {
      // Row 11.11: uploads pause until the new notice is accepted.
      onboarding.reconsentNeeded()
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
    let app = AppModel(
      options: LaunchOptions.parse(arguments: arguments), bundlePath: Bundle.main.bundlePath, bufferReadable: true,
      store: UserDefaultsOnboardingStore(), services: services, probe: LivePermissionProbe(), events: NoLocalEvents(),
      sampleWeek: sampleWeek
    )
    app.trackFrontmostApp()
    return app
  }

  /// True only while the observer really captures (m3-02); the menu bar and screen 13 say so honestly.
  public var isCapturing: Bool { onboarding.services.capture.isRunning }

  public var menuLine: String { MenuBarStatus.line(isCapturing: isCapturing, waiting: 0) }

  public var menuNeverWatchItem: MenuNeverWatchItem? {
    MenuNeverWatch.item(frontmostBundleID: frontmost?.bundleID, frontmostName: frontmost?.name,
                        ownBundleID: Bundle.main.bundleIdentifier, current: neverWatch.currentExclusions())
  }

  /// "Don't watch <app>" from the menu bar: applied on this Mac at once, sent to the account only when sending.
  public func dontWatch(_ exclusion: Exclusion) async {
    await onboarding.perform(.neverWatch(add: [exclusion]))
  }

  public func showNeverWatch() { showingNeverWatch = true }

  /// Follows the app in front (not Offload), for the menu bar entry.
  public func trackFrontmostApp() {
    let own = Bundle.main.bundleIdentifier
    if let app = NSWorkspace.shared.frontmostApplication, let id = app.bundleIdentifier, id != own {
      frontmost = (id, app.localizedName ?? id)
    }
    frontmostObserver = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
    ) { [weak self] note in
      guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
            let id = app.bundleIdentifier, id != own else { return }
      let name = app.localizedName ?? id
      Task { @MainActor [weak self] in self?.frontmost = (id, name) }
    }
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

  /// Screen 0 "Move and reopen" (see AppMover).
  public func moveToApplications() {
    let outcome = AppMover.move(source: Bundle.main.bundleURL, applications: URL(fileURLWithPath: "/Applications"),
                                ops: LiveAppFileOps())
    if case .failed(let message) = outcome { moveError = message }
  }

  public func quit() { NSApp.terminate(nil) }
}
