import AppKit
import SwiftUI

/// The app's root model: decides the launch route, owns the onboarding and permissions models, and switches to Today
/// when setup is done. Everything it calls is injected, so `App/OffloadApp.swift` only wires the live pieces.
@MainActor
public final class AppModel: ObservableObject {
  @Published public private(set) var route: LaunchRoute
  @Published public private(set) var today: TodayModel
  /// The Never watch sheet (menu bar "Never watch an app or site…"), available in every mode.
  @Published public var showingNeverWatch = false
  /// The app in front other than Offload, for the menu bar's "Don't watch <app>".
  @Published public private(set) var frontmost: (bundleID: String, name: String)? = nil
  /// Shown on the move sheet when copying to Applications failed.
  @Published public private(set) var moveError: String? = nil
  public let onboarding: OnboardingModel
  public let permissions: PermissionsModel
  public let events: LocalEventSource
  public let sampleWeek: SampleWeekFlag
  public let neverWatch: NeverWatchStore
  /// m3-10: the navigation shell (the sidebar's selection and the hand-off to Build progress).
  public let navigation: NavigationModel
  /// m3-10: backend mode and the brain and builds clients (none in `.local`).
  public let backends: Backends
  /// m3-10: local insights, counted on this Mac, for Today, Weekly review and Recordings.
  public let insights: InsightsModel
  /// m3-10: the on-device recordings import (the folders found, the local sink); nil when it could not be set up.
  public let onDeviceRecordings: OnDeviceRecordings?
  /// m3-12: the weekly review (its screen, its Settings section and the review notification), built on first use.
  public private(set) lazy var weeklyReview: WeeklyReviewHub = WeeklyReviewHub(app: self)

  private var frontmostObserver: NSObjectProtocol?
  private var backgroundChecks: Task<Void, Never>?

  /// `currentNoticeVersion` is the server's "What leaves your Mac" version from `GET /v1/me` (nil until sign-in
  /// exists, m1-04).
  public init(options: LaunchOptions, bundlePath: String, bufferReadable: Bool, store: OnboardingStore,
              services: OnboardingServices, probe: PermissionProbe, events: LocalEventSource, sampleWeek: SampleWeekFlag,
              currentNoticeVersion: String? = nil, navigation: NavigationModel? = nil, backends: Backends = .local,
              insights: InsightsModel? = nil, onDeviceRecordings: OnDeviceRecordings? = nil) {
    let onboarding = OnboardingModel(store: store, services: services)
    self.onboarding = onboarding
    self.permissions = PermissionsModel(probe: probe, screenRecordingConfirmed: onboarding.state.screenRecordingConfirmed,
                                        listedInSettings: onboarding.state.listedInSettings)
    self.events = events
    self.sampleWeek = sampleWeek
    self.neverWatch = services.neverWatch
    self.navigation = navigation ?? NavigationModel()
    self.backends = backends
    self.insights = insights ?? InsightsModel.empty()
    self.onDeviceRecordings = onDeviceRecordings
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
    // Rows 11.1 and 11.4: both permissions are read at every launch.
    readPermissions(atLaunch: true)
    // Capture resumes after a relaunch once screen 2 was resolved with a permission on.
    if onboarding.state.captureStarted { services.capture.start() }
    // Uploads resume for a person who is sending; never without consent, never while a new notice waits.
    if onboarding.state.sending && !onboarding.state.reconsentPending { services.uploader.start() }
    today = TodayModel(state: onboarding.state, now: Date())
    onboarding.onOpenToday = { [weak self] in self?.showToday() }
  }

  /// One read of both permissions into the saved state. At launch, a Screen Recording grant found on screen 2 means
  /// macOS's own "Quit & Reopen" relaunched Offload: setup resumes at screen 3 with "Screen reading is on."
  func readPermissions(atLaunch: Bool) {
    permissions.tick()
    let ax = permissions.ticker.isGranted(.accessibility)
    let sr = permissions.ticker.isGranted(.screenRecording)
    if atLaunch, route == .onboarding(.permissions), sr, !onboarding.state.screenRecording {
      onboarding.performSync(.screenRecordingOnAtLaunch)
      route = .onboarding(.lastTenMinutes)
    }
    onboarding.performSync(.permissionsRead(accessibility: ax, screenRecording: sr))
  }

  /// Row 11.3: in normal running both permissions are checked every 5 s, so Today's mode and banners stay true.
  public func startBackgroundChecks() {
    backgroundChecks?.cancel()
    backgroundChecks = Task { @MainActor [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: UInt64(PermissionsModel.backgroundInterval * 1_000_000_000))
        guard let self, !Task.isCancelled else { return }
        let before = self.onboarding.state.mode
        self.readPermissions(atLaunch: false)
        if self.onboarding.state.mode != before { self.today = TodayModel(state: self.onboarding.state, now: Date()) }
      }
    }
  }

  /// The app as shipped in this build: real permission checks; sign-in, upload, profile and connections are local
  /// stand-ins (their backends land in later slices); nothing is sent anywhere. m3-10: recordings are read and
  /// analysed on this Mac (OnDeviceRecordings, local insights); backend mode is `.local` until an API base URL and a
  /// member token exist.
  public static func live(arguments: [String] = ProcessInfo.processInfo.arguments) -> AppModel {
    let sampleWeek = SampleWeekFlag()
    // One Never watch store for the observer, the onboarding screens and the recordings import.
    let neverWatch = NeverWatchStore()
    let events: LocalEventSource = NoLocalEvents()
    let backends = Backends.make(mode: BackendMode.resolve(
      baseURL: UserDefaults.standard.string(forKey: BackendMode.baseURLDefaultsKey), tokens: NoMemberToken()))
    let local = LocalAnalysis.live(neverWatch: neverWatch, events: events, mode: backends.mode)
    let services = OnboardingServices(
      account: UnavailableAccountService(), consent: LocalConsentService(), uploader: NoUploader(), capture: NoCapture(),
      profile: LocalProfileService(), neverWatch: neverWatch, exclusions: LocalExclusionService(),
      connections: UnavailableConnectionService(), loginItem: LiveLoginItem(), relauncher: LiveRelauncher(),
      sampleWeek: sampleWeek,
      recordings: local.onDevice?.model ?? RecordingsImportModel.live(neverWatch: neverWatch)
    )
    let app = AppModel(
      options: LaunchOptions.parse(arguments: arguments), bundlePath: Bundle.main.bundlePath, bufferReadable: true,
      store: UserDefaultsOnboardingStore(), services: services, probe: LivePermissionProbe(), events: events,
      sampleWeek: sampleWeek, backends: backends, insights: local.insights, onDeviceRecordings: local.onDevice
    )
    app.startLocalAnalysis(rules: local.rules)
    app.weeklyReview.start()
    app.trackFrontmostApp()
    app.startBackgroundChecks()
    return app
  }

  /// Screen 11 and Settings, Recordings (m3-05).
  public var recordings: RecordingsImportModel? { onboarding.services.recordings }

  /// True only while the observer really captures (m3-02); the menu bar and screen 13 say so honestly.
  public var isCapturing: Bool { onboarding.services.capture.isRunning }

  public var menuLine: String { MenuBarStatus.line(isCapturing: isCapturing, waiting: 0) }

  public var menuNeverWatchItem: MenuNeverWatchItem? {
    MenuNeverWatch.item(frontmostBundleID: frontmost?.bundleID, frontmostName: frontmost?.name,
                        ownBundleID: Bundle.main.bundleIdentifier, current: neverWatch.currentExclusions())
  }

  /// "Don't watch <app>" from the menu bar: applied on this Mac at once, sent to the account only when sending. The
  /// menu reads the store through this model, so it is told to redraw and the entry goes away.
  public func dontWatch(_ exclusion: Exclusion) async {
    await onboarding.perform(.neverWatch(add: [exclusion]))
    objectWillChange.send()
    // m3-10: the counted days drop the app at once, without a new import.
    insights.exclusionsChanged()
  }

  /// The app in front other than Offload.
  public func noteFrontmost(bundleID: String, name: String) {
    guard bundleID != Bundle.main.bundleIdentifier else { return }
    frontmost = (bundleID, name)
  }

  public func showNeverWatch() { showingNeverWatch = true }

  /// Follows the app in front (not Offload), for the menu bar entry.
  public func trackFrontmostApp() {
    let own = Bundle.main.bundleIdentifier
    if let app = NSWorkspace.shared.frontmostApplication, let id = app.bundleIdentifier, id != own {
      noteFrontmost(bundleID: id, name: app.localizedName ?? id)
    }
    frontmostObserver = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
    ) { [weak self] note in
      guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
            let id = app.bundleIdentifier, id != own else { return }
      let name = app.localizedName ?? id
      Task { @MainActor [weak self] in self?.noteFrontmost(bundleID: id, name: name) }
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
      // "Turn on": ask for the missing permission right here (system prompt once, then its Privacy pane). Setup is
      // not walked again.
      let kind: PermissionKind = onboarding.state.accessibility ? .screenRecording : .accessibility
      if permissions.openSettings(for: kind) == .systemPrompt {
        onboarding.performSync(.promptedInSettings(kind))
      }
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
