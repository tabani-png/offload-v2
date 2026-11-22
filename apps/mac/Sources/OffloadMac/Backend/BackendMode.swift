import Foundation

// Backend mode (SPEC m3-10 "Backend/"): `.local` by default; `.cloud` only with an https API base URL and a member
// token. No token exists until enrollment (m1-04, m3-02), so the test build is `.local` and no client exists.

/// Where the Mac gets a member token (audience `member`, API.md section 1). Enrollment provides the real one.
public protocol MemberTokenProvider: Sendable {
  /// The current token, or nil when this Mac is not enrolled or signed in.
  func currentToken() -> String?
}

/// The test build's provider: there is no enrollment yet, so there is never a token.
public struct NoMemberToken: MemberTokenProvider {
  public init() {}
  public func currentToken() -> String? { nil }
}

/// The configured API: base URL (requests go to `<base>/v1/...`) and the token provider. Two configs are equal when
/// their base URLs are; the provider is not compared. Its description shows the base URL only, never a token.
public struct BackendConfig: Equatable, Sendable, CustomStringConvertible {
  public let baseURL: URL
  public let tokens: any MemberTokenProvider

  public init(baseURL: URL, tokens: any MemberTokenProvider) {
    self.baseURL = baseURL
    self.tokens = tokens
  }

  public static func == (lhs: BackendConfig, rhs: BackendConfig) -> Bool {
    lhs.baseURL == rhs.baseURL
  }

  public var description: String { "BackendConfig(\(baseURL.absoluteString))" }
}

public enum BackendMode: Equatable, Sendable, CustomStringConvertible {
  /// Everything is counted on this Mac; no brain or builds client exists.
  case local
  /// The screens read the brain and builds APIs at `config.baseURL`.
  case cloud(BackendConfig)

  /// `UserDefaults` key holding the API base URL (for example `https://api.example.test`).
  public static let baseURLDefaultsKey = "ai.offload.api.baseURL"

  public var isLocal: Bool {
    if case .local = self { return true }
    return false
  }

  public var description: String {
    switch self {
    case .local: return "local"
    case .cloud(let config): return "cloud(\(config.baseURL.absoluteString))"
    }
  }

  /// `.cloud` only when `baseURL` is an `https` URL with a host (no user, password, query or fragment) and the
  /// provider returns a non-empty token; otherwise `.local`.
  public static func resolve(baseURL: String?, tokens: any MemberTokenProvider) -> BackendMode {
    guard let url = validatedBaseURL(baseURL) else { return .local }
    guard let token = tokens.currentToken(), !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return .local
    }
    return .cloud(BackendConfig(baseURL: url, tokens: tokens))
  }

  /// Reads the base URL from `defaults` under `baseURLDefaultsKey`.
  public static func resolve(defaults: UserDefaults, tokens: any MemberTokenProvider) -> BackendMode {
    resolve(baseURL: defaults.string(forKey: baseURLDefaultsKey), tokens: tokens)
  }

  /// The base URL when `raw` is acceptable as the API base, else nil.
  public static func validatedBaseURL(_ raw: String?) -> URL? {
    guard let raw else { return nil }
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, let comps = URLComponents(string: trimmed) else { return nil }
    guard comps.scheme?.lowercased() == "https" else { return nil }
    guard let host = comps.host, !host.isEmpty else { return nil }
    guard comps.user == nil, comps.password == nil, comps.query == nil, comps.fragment == nil else { return nil }
    return comps.url
  }
}

/// What the screens get: the mode, the two clients (both nil in `.local`, so no request can be built) and the
/// provenance of what they show.
public struct Backends: Sendable {
  public let mode: BackendMode
  public let brain: (any BrainClient)?
  public let builds: (any BuildsClient)?
  public let provenance: DataProvenance

  public init(mode: BackendMode, brain: (any BrainClient)?, builds: (any BuildsClient)?, provenance: DataProvenance) {
    self.mode = mode
    self.brain = brain
    self.builds = builds
    self.provenance = provenance
  }

  /// Local mode: no clients, figures counted on this Mac.
  public static let local = Backends(mode: .local, brain: nil, builds: nil, provenance: .onDevice)

  /// `.local` gives `Backends.local`; `.cloud` gives the HTTP brain and builds clients over `transport`, provenance
  /// `.cloud`. A nil `signer` means approvals are refused locally with `APIError.signingUnavailable`.
  public static func make(
    mode: BackendMode,
    transport: (any HTTPTransport)? = nil,
    signer: (any RequestSigner)? = nil
  ) -> Backends {
    switch mode {
    case .local:
      // No networking object at all in `.local` (review 1, finding 10).
      return .local
    case .cloud(let config):
      let core = APIClientCore(config: config, transport: transport ?? URLSessionTransport(), signer: signer)
      return Backends(
        mode: mode,
        brain: HTTPBrainClient(core: core),
        builds: HTTPBuildsClient(core: core),
        provenance: .cloud
      )
    }
  }
}
