import Foundation

// "Never watch these apps or sites" (ONBOARDING screen 9, Q5). Parsing ported from PR #44
// (app/Sources/Core/Recordings.swift `NeverWatch`). Shapes follow DATA_MODEL `exclusions`
// (`kind`: bundle_id, host, title_contains; `source`: builtin, user) and API `POST /v1/exclusions` `{ kind, value }`.

public struct Exclusion: Codable, Hashable, Sendable {
  public enum Kind: String, Codable, Hashable, Sendable {
    case bundleID = "bundle_id"
    case host
    case titleContains = "title_contains"
  }

  public enum Source: String, Codable, Hashable, Sendable {
    case builtin
    case user
  }

  public var kind: Kind
  public var value: String
  public var source: Source

  public init(kind: Kind, value: String, source: Source = .user) {
    self.kind = kind
    self.value = value
    self.source = source
  }
}

/// One typed "Never watch" entry before app names are resolved to bundle ids.
public enum NeverWatchEntry: Equatable, Sendable {
  case appName(String)
  case bundleID(String)
  case host(String)

  /// nil for an app name: the app layer resolves names to bundle ids first.
  public var exclusion: Exclusion? {
    switch self {
    case .appName: return nil
    case .bundleID(let id): return Exclusion(kind: .bundleID, value: id)
    case .host(let h): return Exclusion(kind: .host, value: h)
    }
  }
}

public enum NeverWatch {
  private static let reverseDNSRoots: Set<String> = ["com", "org", "net", "io", "ai", "app", "co", "dev", "us", "de", "uk", "me"]

  /// "Slack, mail.google.com, com.apple.MobileSMS, https://bank.example.com/login" → app name, host, bundle id, host.
  public static func parse(_ text: String) -> [NeverWatchEntry] {
    let pieces = text.split(whereSeparator: { $0 == "," || $0 == "\n" })
    return pieces.compactMap { raw -> NeverWatchEntry? in
      var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !s.isEmpty else { return nil }
      let lower = s.lowercased()
      if lower.hasPrefix("http://") || lower.hasPrefix("https://") {
        guard let host = URL(string: s)?.host else { return nil }
        return .host(host.lowercased())
      }
      if s.contains(" ") || !s.contains(".") { return .appName(s) }
      if s.hasSuffix("/") { s.removeLast() }
      let parts = s.split(separator: ".")
      if parts.count >= 3, let first = parts.first, reverseDNSRoots.contains(first.lowercased()) { return .bundleID(s) }
      return .host(s.lowercased())
    }
  }

  /// Parses and resolves app names with `resolve` (installed apps). Unresolved names are returned so the screen can
  /// say which ones it could not find.
  public static func exclusions(from text: String, resolve: (String) -> String?) -> (exclusions: [Exclusion], unresolved: [String]) {
    var found: [Exclusion] = []
    var unresolved: [String] = []
    for entry in parse(text) {
      switch entry {
      case .appName(let name):
        if let id = resolve(name) { found.append(Exclusion(kind: .bundleID, value: id)) } else { unresolved.append(name) }
      default:
        if let e = entry.exclusion { found.append(e) }
      }
    }
    var seen = Set<Exclusion>()
    return (found.filter { seen.insert($0).inserted }, unresolved)
  }
}

/// A chip on screen 9. Locked chips are on from the start and cannot be turned off.
public struct NeverWatchChip: Equatable, Sendable, Identifiable {
  public var id: String
  public var label: String
  public var isLocked: Bool
  /// What the chip adds. Banking sites are covered by the observer's built-in list (m3-02,
  /// `packages/masking/src/exclusions.builtin.json`), so that chip carries no entries of its own here.
  public var exclusions: [Exclusion]

  public static let locked: [NeverWatchChip] = [
    NeverWatchChip(id: "1password", label: "1Password", isLocked: true, exclusions: [
      Exclusion(kind: .bundleID, value: "com.1password.1password", source: .builtin),
      Exclusion(kind: .bundleID, value: "com.agilebits.onepassword7", source: .builtin),
    ]),
    NeverWatchChip(id: "banking", label: "Banking sites", isLocked: true, exclusions: []),
    NeverWatchChip(id: "private", label: "Private windows", isLocked: true, exclusions: [
      Exclusion(kind: .titleContains, value: "Private Browsing", source: .builtin),
      Exclusion(kind: .titleContains, value: "InPrivate", source: .builtin),
      Exclusion(kind: .titleContains, value: "Incognito", source: .builtin),
    ]),
  ]

  /// Optional chips. "Personal Chrome profile" waits for a profile-aware exclusion kind (see the SPEC).
  public static let optional: [NeverWatchChip] = [
    NeverWatchChip(id: "messages", label: "Messages", isLocked: false, exclusions: [Exclusion(kind: .bundleID, value: "com.apple.MobileSMS")]),
    NeverWatchChip(id: "whatsapp", label: "WhatsApp", isLocked: false, exclusions: [Exclusion(kind: .bundleID, value: "net.whatsapp.WhatsApp")]),
    NeverWatchChip(id: "photos", label: "Photos", isLocked: false, exclusions: [Exclusion(kind: .bundleID, value: "com.apple.Photos")]),
    NeverWatchChip(id: "spotify", label: "Spotify", isLocked: false, exclusions: [Exclusion(kind: .bundleID, value: "com.spotify.client")]),
  ]

  public static var lockedExclusions: [Exclusion] { locked.flatMap(\.exclusions) }
}

/// What the observer reads to decide what it never watches. The m3-02 observer reloads it every 2 s, so an entry
/// added here stops being seen within one check.
public protocol ExclusionSource: Sendable {
  func currentExclusions() -> [Exclusion]
}

/// The Mac's copy of the exclusions: built-ins (locked) plus the person's own. Written before any server call, so a
/// skipped or failed call never leaves a "never watch" app watched. Thread-safe: the observer reads it off the main
/// thread.
public final class NeverWatchStore: ExclusionSource, @unchecked Sendable {
  private let lock = NSLock()
  private let builtIn: [Exclusion]
  private var user: [Exclusion]

  public init(builtIn: [Exclusion] = NeverWatchChip.lockedExclusions, user: [Exclusion] = []) {
    self.builtIn = builtIn
    var seen = Set<Exclusion>()
    self.user = user.filter { $0.source == .user && seen.insert($0).inserted }
  }

  public func currentExclusions() -> [Exclusion] {
    lock.lock()
    defer { lock.unlock() }
    return builtIn + user
  }

  public var userExclusions: [Exclusion] {
    lock.lock()
    defer { lock.unlock() }
    return user
  }

  /// Adds the person's entries (duplicates and built-ins are ignored).
  public func add(_ entries: [Exclusion]) {
    lock.lock()
    defer { lock.unlock() }
    for e in entries where e.source == .user && !user.contains(e) && !builtIn.contains(e) {
      user.append(e)
    }
  }

  /// Removes one of the person's entries. Built-in (locked) entries cannot be removed: returns false.
  @discardableResult
  public func remove(_ entry: Exclusion) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard entry.source == .user, let i = user.firstIndex(of: entry) else { return false }
    user.remove(at: i)
    return true
  }
}
