import Foundation

// The local now summary: what the observer saw in the last N minutes, counted in code on this Mac. Rewritten in
// Swift from the old brain's GET /now (PR #44, brain/src/time/now.ts and the sessionize rules it used): top 3 apps by
// active minutes, app switches inside the window, idle excluded. No model call, nothing uploaded, no networking API
// in this folder (test NOW-6).

/// One line of a local day file, in the old s34 shape. Unknown keys (masked text, hashes) are ignored.
public struct LocalEvent: Codable, Equatable, Sendable {
  public var id: String
  /// Milliseconds since 1970.
  public var ts: Int64
  /// `focus`, `idle_start`, `idle_end`, `pause`, `resume`, or a content kind (`ocr`, `text_snapshot`, `input`).
  public var kind: String
  public var app: String?
  public var appName: String?

  public init(id: String, ts: Int64, kind: String, app: String?, appName: String?) {
    self.id = id
    self.ts = ts
    self.kind = kind
    self.app = app
    self.appName = appName
  }

  /// JSON lines; blank lines are skipped.
  public static func decodeLines(_ text: String) throws -> [LocalEvent] {
    let decoder = JSONDecoder()
    var out: [LocalEvent] = []
    for raw in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
      let line = raw.trimmingCharacters(in: .whitespaces)
      if line.isEmpty { continue }
      out.append(try decoder.decode(LocalEvent.self, from: Data(line.utf8)))
    }
    return out
  }
}

/// Where the summary reads local spans from. The m3-02 store implements it over the encrypted local buffer.
public protocol LocalEventSource: Sendable {
  /// Events with `from < ts <= to`, plus the last focus before `from` so focus carries into the window.
  func events(from: Int64, to: Int64) -> [LocalEvent]
  /// When capture first ran on this Mac (ms), if it has.
  func captureStartedAt() -> Int64?
}

/// Until the observer lands (m3-02): nothing seen, honestly.
public struct NoLocalEvents: LocalEventSource {
  public init() {}
  public func events(from: Int64, to: Int64) -> [LocalEvent] { [] }
  public func captureStartedAt() -> Int64? { nil }
}

public struct NowApp: Equatable, Sendable {
  public var app: String
  public var appName: String
  /// Whole minutes, rounded half up; the line uses the same value.
  public var minutes: Int
  public var activeMs: Int64
  public var eventIds: [String]
}

public struct LocalNowSummary: Equatable, Sendable {
  /// The span the line covers: the requested minutes, or less when capture has run for less.
  public var minutes: Int
  public var activeMinutes: Int
  /// Active time in the window, all apps together.
  public var activeMs: Int64
  public var top: [NowApp]
  public var switches: Int
  public var switchesPerMinute: Double
  public var headline: String
  public var line: String
  public var remark: String
  public var computedBy: String

  /// The observer writes `idle_start` this long after the last input; readers move it back by this much.
  public static let idleThresholdMs: Int64 = 120_000
  static let minuteMs: Int64 = 60_000

  public var isEmpty: Bool { top.isEmpty }
  /// "Nothing seen yet" until there is at least one active minute in the window (ONBOARDING section 5).
  public var hasActiveMinute: Bool { activeMs >= Self.minuteMs }
  /// The pointer flies only once some app has a full minute of active time.
  public var hasFullMinute: Bool { top.contains { $0.activeMs >= Self.minuteMs } }

  static func wholeMinutes(_ ms: Int64) -> Int { Int((Double(ms) / Double(minuteMs) + 0.5).rounded(.down)) }

  public static func compute(events: [LocalEvent], now: Int64, minutes: Int = 10, captureStartedAt: Int64? = nil) -> LocalNowSummary {
    var span = max(1, minutes)
    if let start = captureStartedAt, now - start < Int64(span) * minuteMs {
      span = max(1, Int((now - start) / minuteMs))
    }
    let from = now - Int64(span) * minuteMs
    var upTo = events.filter { $0.ts <= now }
    // Close the open span at now: an idle_start one threshold later is backdated to now.
    upTo.append(LocalEvent(id: "__now__", ts: now + idleThresholdMs, kind: "idle_start", app: nil, appName: nil))
    let segments = toSegments(upTo)

    var order: [String] = []
    var byApp: [String: NowApp] = [:]
    var activeMs: Int64 = 0
    var switches = 0
    var lastApp: String?
    for s in segments {
      let start = max(s.start, from)
      let end = min(s.end, now)
      if end <= start { continue }
      let active = end - start
      if let last = lastApp, last != s.app { switches += 1 }
      lastApp = s.app
      activeMs += active
      var a = byApp[s.app] ?? NowApp(app: s.app, appName: s.appName, minutes: 0, activeMs: 0, eventIds: [])
      if byApp[s.app] == nil { order.append(s.app) }
      a.activeMs += active
      for id in s.eventIds where !a.eventIds.contains(id) { a.eventIds.append(id) }
      byApp[s.app] = a
    }
    let ranked = order.compactMap { byApp[$0] }.enumerated().sorted { x, y in
      x.element.activeMs != y.element.activeMs ? x.element.activeMs > y.element.activeMs : x.offset < y.offset
    }
    let top = ranked.prefix(3).map { pair -> NowApp in
      var a = pair.element
      a.minutes = wholeMinutes(a.activeMs)
      return a
    }
    return LocalNowSummary(
      minutes: span,
      activeMinutes: wholeMinutes(activeMs),
      activeMs: activeMs,
      top: Array(top),
      switches: switches,
      switchesPerMinute: Double(switches) / Double(span),
      headline: headlineText(span: span),
      line: activeMs >= minuteMs ? lineText(span: span, top: Array(top), switches: switches) : nothingSeen,
      remark: activeMs >= minuteMs ? remarkText(top: Array(top)) : "",
      computedBy: "code"
    )
  }

  static func headlineText(span: Int) -> String {
    span == 1 ? "Here's your last minute." : "Here's your last \(span) minutes."
  }

  static let nothingSeen = "Nothing seen yet. Keep working for a minute."

  static func lineText(span: Int, top: [NowApp], switches: Int) -> String {
    guard !top.isEmpty else { return nothingSeen }
    let apps = top.map { "\($0.appName) \($0.minutes)m" }
    let sw = switches == 1 ? "1 switch" : "\(switches) switches"
    return (["\(span) min"] + apps + [sw]).joined(separator: " · ")
  }

  /// Lowercase, from the numbers: the app with the most active time, at most three of its words.
  static func remarkText(top: [NowApp]) -> String {
    guard let first = top.first else { return "" }
    let name = first.appName.lowercased().split(whereSeparator: { $0 == " " }).prefix(3).joined(separator: " ")
    return "that's you, mostly in \(name)."
  }

  // MARK: - Segments (the old sessionize pass 1, without day carry-over)

  struct Segment {
    var app: String
    var appName: String
    var start: Int64
    var end: Int64
    var eventIds: [String]
    var hasContent: Bool
  }

  struct Focus {
    var app: String
    var appName: String
    var eventId: String
  }

  static func toSegments(_ events: [LocalEvent]) -> [Segment] {
    let sorted = events.sorted { a, b in a.ts != b.ts ? a.ts < b.ts : a.id < b.id }
    var out: [Segment] = []
    var cur: Segment?
    var last: Focus?
    var paused = false

    func close(_ ts: Int64) {
      guard var c = cur else { return }
      c.end = max(c.start, ts)
      if !c.eventIds.isEmpty { out.append(c) }
      cur = nil
    }

    for e in sorted {
      switch e.kind {
      case "focus":
        close(e.ts)
        let app = e.app ?? "unknown"
        let f = Focus(app: app, appName: e.appName ?? app, eventId: e.id)
        last = f
        if !paused { cur = Segment(app: f.app, appName: f.appName, start: e.ts, end: e.ts, eventIds: [e.id], hasContent: false) }
      case "idle_start":
        let cutoff = e.ts - idleThresholdMs
        if let c = cur, cutoff <= c.start, !c.hasContent { cur = nil }
        close(cutoff)
        var i = out.count - 1
        while i >= 0 {
          if out[i].end <= cutoff { break }
          out[i].end = max(out[i].start, cutoff)
          i -= 1
        }
      case "idle_end":
        if !paused, cur == nil, let f = last {
          cur = Segment(app: f.app, appName: f.appName, start: e.ts, end: e.ts, eventIds: [f.eventId, e.id], hasContent: false)
        }
      case "pause":
        close(e.ts)
        paused = true
        last = nil
      case "resume":
        paused = false
      default:
        if cur != nil {
          cur?.eventIds.append(e.id)
          cur?.hasContent = true
        }
      }
    }
    if let lastEvent = sorted.last { close(lastEvent.ts) }
    return out
  }
}

/// Screen 3's state: refresh every 5 s, the pointer flies once, the "turn on access later" line after 2 minutes of
/// nothing.
public struct LastTenMinutesState: Equatable, Sendable {
  public static let refreshEvery: Double = 5
  public static let nothingGrace: Double = 120

  public let openedAt: Date
  public private(set) var summary: LocalNowSummary?
  public private(set) var pointerFlown = false

  public init(openedAt: Date) { self.openedAt = openedAt }

  /// Takes a fresh summary; true when the pointer should fly to the line now (once, at the first full minute).
  public mutating func received(_ s: LocalNowSummary) -> Bool {
    summary = s
    guard !pointerFlown, s.hasFullMinute else { return false }
    pointerFlown = true
    return true
  }

  public func shouldRefresh(lastRefresh: Date?, now: Date) -> Bool {
    guard let lastRefresh else { return true }
    return now.timeIntervalSince(lastRefresh) >= Self.refreshEvery
  }

  public var seesSomething: Bool { summary?.hasActiveMinute ?? false }

  /// The remark appears with the pointer, once some app has a full active minute.
  public var showsRemark: Bool { pointerFlown }

  public func showsAccessLaterLine(now: Date) -> Bool {
    !seesSomething && now.timeIntervalSince(openedAt) >= Self.nothingGrace
  }
}
