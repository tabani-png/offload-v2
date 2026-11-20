import Foundation

// The person's exclusions apply to imports exactly as to live capture: an excluded app keeps its time (a focus with
// the app name only) but gets no title, no host, no text and no keyframe. The rules mirror DATA_MODEL `exclusions`
// (`bundle_id`, `host`, `title_contains`); the app passes its Never watch list in (OffloadMac
// `NeverWatchImportExclusions`), read again before every file.

public struct ImportExclusionRule: Equatable, Hashable, Sendable {
  public enum Kind: String, Sendable {
    case bundleID = "bundle_id"
    case host
    case titleContains = "title_contains"
  }

  public var kind: Kind
  public var value: String
  /// For a `bundle_id` rule: the app's display name ("Photos", "Acme Ledger"). A recording knows its app only by the
  /// name its menu bar shows, so an app that is in no built-in table is matched by this name (review 2).
  public var appName: String?

  public init(kind: Kind, value: String, appName: String? = nil) {
    self.kind = kind
    self.value = value
    self.appName = appName
  }
}

public protocol ImportExclusionSource: Sendable {
  func currentRules() -> [ImportExclusionRule]
}

/// A fixed list (tests, and imports started without a Never watch store).
public struct StaticImportExclusions: ImportExclusionSource {
  public var rules: [ImportExclusionRule]
  public init(_ rules: [ImportExclusionRule]) { self.rules = rules }
  public func currentRules() -> [ImportExclusionRule] { rules }
}

public enum ImportExclusions {
  /// Password managers and authenticators by the name the menu bar shows (PR #44 `excludedAppNames`).
  static let appNames: Set<String> = [
    "1password", "1password 7", "1password 8", "bitwarden", "dashlane", "lastpass", "keepassxc", "keychain access",
    "passwords", "enpass", "proton pass", "authy", "authy desktop", "microsoft authenticator", "yubico authenticator",
    // The banking apps of `bundleIDs`, by the names their menu bars show (review 2).
    "moneymoney", "banktivity", "banktivity 7", "banktivity 8", "quicken",
  ]
  /// Password managers, authenticators and banking apps by bundle id (s34 `folder.ts` DENY_BUNDLES).
  static let bundleIDs: Set<String> = [
    "com.1password.1password", "com.agilebits.onepassword7", "com.agilebits.onepassword-osx", "com.bitwarden.desktop",
    "org.keepassxc.keepassxc", "com.lastpass.lastpass", "com.dashlane.dashlanephonefinal", "com.apple.passwords",
    "com.apple.keychainaccess", "com.authy.authy-mac", "com.microsoft.azureauthenticator", "com.yubico.yubioath",
    "com.moneymoney-app.retail", "com.iggsoftware.banktivity7", "com.iggsoftware.banktivity8", "com.quicken.quicken",
  ]
  /// Banking and password sites (s34 `folder.ts` DENY_DOMAINS), with their subdomains.
  static let hosts: [String] = [
    "chase.com", "bankofamerica.com", "wellsfargo.com", "citi.com", "capitalone.com", "usbank.com", "pnc.com", "ally.com",
    "americanexpress.com", "rbcroyalbank.com", "td.com", "scotiabank.com", "bmo.com", "cibc.com", "tangerine.ca",
    "revolut.com", "monzo.com", "n26.com", "wise.com", "mercury.com", "1password.com", "bitwarden.com", "lastpass.com",
  ]
  /// Private browsing windows by their title.
  static let privateMarkers: [String] = ["private browsing", "incognito", "inprivate", "private window"]

  /// True when nothing but the app name may be kept for this moment.
  public static func isExcluded(bundleID: String, appName: String, title: String?, host: String?,
                                rules: [ImportExclusionRule]) -> Bool {
    let bundle = bundleID.lowercased()
    let name = appName.lowercased()
    let lowTitle = title?.lowercased() ?? ""
    let lowHost = host?.lowercased() ?? ""
    if appNames.contains(name) || bundleIDs.contains(bundle) { return true }
    if !lowTitle.isEmpty, privateMarkers.contains(where: { lowTitle.contains($0) }) { return true }
    if !lowHost.isEmpty, hosts.contains(where: { matches(host: lowHost, rule: $0) }) { return true }
    for rule in rules {
      let value = rule.value.lowercased()
      guard !value.isEmpty else { continue }
      switch rule.kind {
      case .bundleID:
        if bundle == value { return true }
        if let ruleName = rule.appName?.lowercased(), !ruleName.isEmpty, ruleName == name { return true }
      case .host: if !lowHost.isEmpty && matches(host: lowHost, rule: value) { return true }
      case .titleContains: if lowTitle.contains(value) { return true }
      }
    }
    return false
  }

  static func matches(host: String, rule: String) -> Bool {
    host == rule || host.hasSuffix("." + rule)
  }

  /// For a recording or screenshot, which has no window title or URL: the frame is excluded when any OCR line shows
  /// an excluded host (in an address bar or a link), a `title_contains` value, or a private-window marker. Errs on
  /// the side of excluding: a frame that merely mentions a rule's word gets no text either.
  public static func isExcluded(bundleID: String, appName: String, lines: [String], rules: [ImportExclusionRule]) -> Bool {
    if isExcluded(bundleID: bundleID, appName: appName, title: nil, host: nil, rules: rules) { return true }
    let text = lines.joined(separator: "\n")
    for host in hosts(in: lines) where isExcluded(bundleID: bundleID, appName: appName, title: nil, host: host, rules: rules) {
      return true
    }
    return isExcluded(bundleID: bundleID, appName: appName, title: text, host: nil, rules: rules)
  }

  /// Host names in OCR text: tokens like `https://secure.chase.com/login` or `mail.example.org/inbox`, lowercased,
  /// without scheme, path or surrounding punctuation. The last label must hold a letter (so "1.5" is not a host).
  public static func hosts(in lines: [String]) -> [String] {
    var out: [String] = []
    for line in lines {
      for raw in line.split(whereSeparator: { $0.isWhitespace }) {
        var token = raw.lowercased()
        if let r = token.range(of: "://") { token = String(token[r.upperBound...]) }
        if let slash = token.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) { token = String(token[..<slash]) }
        token = token.trimmingCharacters(in: CharacterSet(charactersIn: "()[]<>{}\"'.,;:!"))
        if let at = token.lastIndex(of: "@") { token = String(token[token.index(after: at)...]) }
        guard token.range(of: #"^[a-z0-9-]+(\.[a-z0-9-]+)+$"#, options: .regularExpression) != nil,
              let last = token.split(separator: ".").last, last.contains(where: { $0.isLetter }) else { continue }
        if !out.contains(token) { out.append(token) }
      }
    }
    return out
  }
}

/// At most one keyframe per `minGap` seconds of recording time, and only when the picture changed: a Hamming
/// distance of at least `minDistance` on the 64-bit perceptual hash (the live observer's keyframe throttle).
public struct KeyframeThrottle: Sendable {
  public static let defaultMinGap: TimeInterval = 20
  public static let defaultMinDistance = 10

  public let minGap: TimeInterval
  public let minDistance: Int
  private var last: (at: TimeInterval, hash: UInt64)?

  public init(minGap: TimeInterval = KeyframeThrottle.defaultMinGap, minDistance: Int = KeyframeThrottle.defaultMinDistance) {
    self.minGap = minGap
    self.minDistance = minDistance
  }

  /// Cheap check before hashing: false while the last keyframe is too recent.
  public func mightKeep(at t: TimeInterval) -> Bool {
    guard let last else { return true }
    return t - last.at >= minGap
  }

  /// Decides for a frame at `t` with `hash`, and remembers it when kept.
  public mutating func keep(at t: TimeInterval, hash: UInt64) -> Bool {
    if let last {
      guard t - last.at >= minGap, (last.hash ^ hash).nonzeroBitCount >= minDistance else { return false }
    }
    last = (t, hash)
    return true
  }
}
