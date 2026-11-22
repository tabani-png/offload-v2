import Foundation

// What local insights read: one event of what happened on screen, from an import kept on this Mac (LocalImportSink's
// StoredObservation lines) or from live capture (m3-04's LocalEvent, which m3-02 fills). No text, no pixels: an app,
// a masked title, a host and a time.

public struct InsightEvent: Equatable, Sendable {
  public enum Kind: String, Sendable {
    case focus
    case idleStart = "idle_start"
    case idleEnd = "idle_end"
    case textSnapshot = "text_snapshot"
    case pause
    case resume
  }

  public enum Origin: Equatable, Hashable, Sendable {
    case live
    case imported(String)
  }

  public var id: String
  public var ts: Date
  public var kind: Kind
  public var appBundleID: String?
  public var appName: String?
  public var title: String?
  public var host: String?
  public var origin: Origin

  public init(id: String, ts: Date, kind: Kind, appBundleID: String? = nil, appName: String? = nil, title: String? = nil,
              host: String? = nil, origin: Origin) {
    self.id = id
    self.ts = ts
    self.kind = kind
    self.appBundleID = appBundleID
    self.appName = appName
    self.title = title
    self.host = host
    self.origin = origin
  }

  /// A line of an import kept on this Mac. Nil for a kind insights do not read or a time that does not parse.
  public init?(stored s: StoredObservation) {
    guard let kind = Kind(rawValue: s.kind), let ts = LocalDays.parseRFC3339(s.ts) else { return nil }
    self.init(id: s.id, ts: ts, kind: kind, appBundleID: s.appBundleID, appName: s.appName, title: s.title, host: s.host,
              origin: .imported(s.importID))
  }

  /// A live event (m3-04's local buffer shape). Content kinds (`ocr`, `text_snapshot`, `input`) are activity.
  public init?(local e: LocalEvent) {
    let kind: Kind
    switch e.kind {
    case "focus": kind = .focus
    case "idle_start": kind = .idleStart
    case "idle_end": kind = .idleEnd
    case "pause": kind = .pause
    case "resume": kind = .resume
    case "ocr", "text_snapshot", "input": kind = .textSnapshot
    default: return nil
    }
    self.init(id: e.id, ts: Date(timeIntervalSince1970: TimeInterval(e.ts) / 1000), kind: kind, appBundleID: e.app,
              appName: e.appName ?? e.app, origin: .live)
  }
}

/// Where insights read events from (the imports kept on this Mac).
public protocol InsightEventReader: Sendable {
  /// Events with `interval.start <= ts < interval.end`.
  func events(in interval: DateInterval) -> [InsightEvent]
  /// Every day (YYYY-MM-DD in `timeZone`) that holds an event.
  func dayLabels(timeZone: TimeZone) -> [String]
}

/// Nothing to read (tests, and the app before anything was imported).
public struct NoInsightEvents: InsightEventReader {
  public init() {}
  public func events(in interval: DateInterval) -> [InsightEvent] { [] }
  public func dayLabels(timeZone: TimeZone) -> [String] { [] }
}

/// Live capture through m3-04's `LocalEventSource`, so the same engine counts live time once m3-02 fills the source.
public struct LocalEventInsightSource: Sendable {
  public let source: any LocalEventSource

  public init(source: any LocalEventSource) { self.source = source }

  public func events(in interval: DateInterval) -> [InsightEvent] {
    let from = Int64((interval.start.timeIntervalSince1970 * 1000).rounded(.down)) - 1
    let to = Int64((interval.end.timeIntervalSince1970 * 1000).rounded(.down))
    return source.events(from: from, to: to).compactMap { InsightEvent(local: $0) }
  }
}

/// Days as the person's calendar has them.
public enum LocalDays {
  public static func calendar(_ timeZone: TimeZone) -> Calendar {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = timeZone
    return cal
  }

  /// "2026-11-20".
  public static func label(_ date: Date, timeZone: TimeZone) -> String {
    let c = calendar(timeZone).dateComponents([.year, .month, .day], from: date)
    return String(format: "%04ld-%02ld-%02ld", c.year ?? 0, c.month ?? 0, c.day ?? 0)
  }

  /// The day's start (local midnight), or nil for a label that is not a day.
  public static func start(of label: String, timeZone: TimeZone) -> Date? {
    let parts = label.split(separator: "-").compactMap { Int($0) }
    guard parts.count == 3 else { return nil }
    return calendar(timeZone).date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
  }

  public static func interval(of label: String, timeZone: TimeZone) -> DateInterval? {
    guard let start = start(of: label, timeZone: timeZone),
          let end = calendar(timeZone).date(byAdding: .day, value: 1, to: start) else { return nil }
    return DateInterval(start: start, end: end)
  }

  /// Every day from `from` to `to` inclusive (either order).
  public static func labels(from: Date, to: Date, timeZone: TimeZone) -> [String] {
    let cal = calendar(timeZone)
    var day = cal.startOfDay(for: min(from, to))
    let last = cal.startOfDay(for: max(from, to))
    var out: [String] = []
    while day <= last {
      out.append(label(day, timeZone: timeZone))
      guard let next = cal.date(byAdding: .day, value: 1, to: day) else { break }
      day = next
    }
    return out
  }

  /// Days from the first to the last label inclusive (1 for a single day, 0 for none).
  public static func span(_ labels: [String], timeZone: TimeZone) -> Int {
    guard let first = labels.min(), let last = labels.max(),
          let a = start(of: first, timeZone: timeZone), let b = start(of: last, timeZone: timeZone) else { return 0 }
    let days = calendar(timeZone).dateComponents([.day], from: a, to: b).day ?? 0
    return days + 1
  }

  /// "2026-W47": ISO 8601 weeks, Monday first, in the person's time zone.
  public static func isoWeek(_ date: Date, timeZone: TimeZone) -> String {
    var cal = Calendar(identifier: .iso8601)
    cal.timeZone = timeZone
    let c = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
    return String(format: "%04ld-W%02ld", c.yearForWeekOfYear ?? 0, c.weekOfYear ?? 0)
  }

  /// RFC 3339 with or without fractional seconds. The stored shape (`2026-11-20T09:41:07.000Z`, ImportWire.rfc3339)
  /// is read without a formatter, because an import holds thousands of lines.
  public static func parseRFC3339(_ s: String) -> Date? {
    if let d = fastUTC(s) { return d }
    let withFraction = ISO8601DateFormatter()
    withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let d = withFraction.date(from: s) { return d }
    let plain = ISO8601DateFormatter()
    plain.formatOptions = [.withInternetDateTime]
    return plain.date(from: s)
  }

  /// `YYYY-MM-DDTHH:MM:SS.mmmZ` only; nil for anything else.
  static func fastUTC(_ s: String) -> Date? {
    let u = Array(s.utf8)
    guard u.count == 24, u[4] == 45, u[7] == 45, u[10] == 84, u[13] == 58, u[16] == 58, u[19] == 46, u[23] == 90 else {
      return nil
    }
    func num(_ from: Int, _ to: Int) -> Int? {
      var n = 0
      for i in from..<to {
        let c = Int(u[i]) - 48
        guard c >= 0, c <= 9 else { return nil }
        n = n * 10 + c
      }
      return n
    }
    guard var y = num(0, 4), let m = num(5, 7), let d = num(8, 10), let h = num(11, 13), let mi = num(14, 16),
          let sec = num(17, 19), let ms = num(20, 23), (1...12).contains(m), (1...31).contains(d), h < 24, mi < 60,
          sec < 61 else { return nil }
    // Days from 1970-01-01 (H. Hinnant's days_from_civil).
    y -= m <= 2 ? 1 : 0
    let era = (y >= 0 ? y : y - 399) / 400
    let yoe = y - era * 400
    let doy = (153 * (m + (m > 2 ? -3 : 9)) + 2) / 5 + d - 1
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
    let days = era * 146_097 + doe - 719_468
    let seconds = Double(days * 86_400 + h * 3600 + mi * 60 + sec) + Double(ms) / 1000
    return Date(timeIntervalSince1970: seconds)
  }
}
