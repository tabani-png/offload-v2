import Foundation

// The services the onboarding screens call. Each backend lands in a later slice, so each is a protocol: tests use
// fakes, and the app uses the local stand-ins at the bottom, which make no network call and say so honestly.

/// Screen 4: browser sign-in and device enrollment (m1-04, the m3-02 enrollment client).
@MainActor public protocol AccountService: AnyObject {
  func signIn() async -> SignInResult
}

/// Screen 5: `POST /v1/me/consents` with notice `what-leaves-your-mac` (m3-02).
@MainActor public protocol ConsentService: AnyObject {
  func recordUploadConsent(noticeVersion: String) async throws
}

/// The uploader (m3-02). Started only after "Start sending".
@MainActor public protocol Uploader: AnyObject {
  func start()
  func pause()
}

extension Uploader {
  public func pause() {}
}

/// The observer (m3-02). Started when screen 2 is resolved with a permission on.
@MainActor public protocol CaptureControl: AnyObject {
  func start()
}

/// `PATCH /v1/profile` (M5). Only answered fields are sent.
@MainActor public protocol ProfileService: AnyObject {
  func patch(_ update: ProfileUpdate) async throws
}

/// `POST /v1/exclusions` (M3). Called only after the entries are applied on the Mac.
@MainActor public protocol ExclusionService: AnyObject {
  func upload(_ exclusions: [Exclusion]) async throws
}

public enum ConnectResult: Equatable, Sendable {
  case connected(account: String)
  case cancelled
  case scopeDenied
  case timedOut
  case offline
  case unavailable
}

/// `POST /v1/connections` and the browser authorization (M2/M5).
@MainActor public protocol ConnectionService: AnyObject {
  func connect(appID: String) async -> ConnectResult
}

/// `SMAppService` login item.
@MainActor public protocol LoginItemService: AnyObject {
  func setEnabled(_ on: Bool)
}

/// Quits and reopens the app after the Screen Recording grant.
@MainActor public protocol Relauncher: AnyObject {
  func relaunch()
}

/// "Look at a sample week": bundled sample data, no account, no network.
@MainActor public protocol SampleWeekPresenter: AnyObject {
  func show()
}

@MainActor public struct OnboardingServices {
  public var account: AccountService
  public var consent: ConsentService
  public var uploader: Uploader
  public var capture: CaptureControl
  public var profile: ProfileService
  public var neverWatch: NeverWatchStore
  public var exclusions: ExclusionService
  public var connections: ConnectionService
  public var loginItem: LoginItemService
  public var relauncher: Relauncher
  public var sampleWeek: SampleWeekPresenter

  public init(account: AccountService, consent: ConsentService, uploader: Uploader, capture: CaptureControl,
              profile: ProfileService, neverWatch: NeverWatchStore, exclusions: ExclusionService,
              connections: ConnectionService, loginItem: LoginItemService, relauncher: Relauncher,
              sampleWeek: SampleWeekPresenter) {
    self.account = account
    self.consent = consent
    self.uploader = uploader
    self.capture = capture
    self.profile = profile
    self.neverWatch = neverWatch
    self.exclusions = exclusions
    self.connections = connections
    self.loginItem = loginItem
    self.relauncher = relauncher
    self.sampleWeek = sampleWeek
  }
}

/// One app on screen 10, from the connection catalog.
public struct CatalogApp: Equatable, Sendable, Identifiable {
  public enum Path: Equatable, Sendable { case direct, composio }
  public var id: String
  public var name: String
  public var path: Path
  public var pathLine: String {
    switch path {
    case .direct: return "Connects directly"
    case .composio: return "Connects through Composio"
    }
  }
}

/// The launch catalog shown until `GET /v1/connections` lands (ADR 0033 owns the real list).
public enum ConnectionCatalog {
  public static let launch: [CatalogApp] = [
    CatalogApp(id: "gmail", name: "Gmail", path: .direct),
    CatalogApp(id: "google-calendar", name: "Google Calendar", path: .direct),
    CatalogApp(id: "google-sheets", name: "Google Sheets", path: .direct),
    CatalogApp(id: "slack", name: "Slack", path: .composio),
    CatalogApp(id: "notion", name: "Notion", path: .direct),
    CatalogApp(id: "linear", name: "Linear", path: .direct),
  ]
}

// MARK: - Local stand-ins for this build (no network, nothing uploaded)

/// Sign-in is not built yet (m1-04): it says so, and "Not now" keeps Offload in Local mode.
@MainActor public final class UnavailableAccountService: AccountService {
  public init() {}
  public func signIn() async -> SignInResult { .unavailable }
}

/// Never reached in this build (no sign-in, so no screen 5), and records nothing remotely if it were.
@MainActor public final class LocalConsentService: ConsentService {
  public private(set) var recordedVersions: [String] = []
  public init() {}
  public func recordUploadConsent(noticeVersion: String) async throws { recordedVersions.append(noticeVersion) }
}

/// No uploader until m3-02: starting it does nothing.
@MainActor public final class NoUploader: Uploader {
  public init() {}
  public func start() {}
}

/// No observer until m3-02: starting capture does nothing.
@MainActor public final class NoCapture: CaptureControl {
  public init() {}
  public func start() {}
}

/// Answers stay in the saved onboarding state until `PATCH /v1/profile` exists (M5).
@MainActor public final class LocalProfileService: ProfileService {
  public init() {}
  public func patch(_ update: ProfileUpdate) async throws {}
}

/// Exclusions apply on the Mac (NeverWatchStore); the account copy waits for sign-in.
@MainActor public final class LocalExclusionService: ExclusionService {
  public init() {}
  public func upload(_ exclusions: [Exclusion]) async throws {}
}

@MainActor public final class UnavailableConnectionService: ConnectionService {
  public init() {}
  public func connect(appID: String) async -> ConnectResult { .unavailable }
}
