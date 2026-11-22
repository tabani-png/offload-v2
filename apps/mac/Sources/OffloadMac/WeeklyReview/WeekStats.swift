import CryptoKit
import Foundation

// One ISO week of m3-10's local insights, and the small arithmetic the review needs over weeks (median, runs). Pure.

public struct WeekStats: Equatable, Sendable {
  public var week: ISOWeek
  /// The week's days with data, oldest first.
  public var days: [DayInsights]

  public init(week: ISOWeek, days: [DayInsights]) {
    self.week = week
    self.days = days
  }

  public var hasData: Bool { !days.isEmpty }
  public var activeSeconds: TimeInterval { days.reduce(0) { $0 + $1.activeSeconds.value } }
  public var focusSeconds: TimeInterval { days.reduce(0) { $0 + $1.focusSeconds.value } }
  public var focusBlocks: Int { Int(days.reduce(0) { $0 + $1.focusBlocks.value }) }
  public var switches: Int { Int(days.reduce(0) { $0 + $1.switches.value }) }

  /// Hours with one decimal.
  public var activeHours: Double { Self.hours(activeSeconds) }
  public var focusHours: Double { Self.hours(focusSeconds) }
  /// Active minutes, whole: the divisor the switches arithmetic shows.
  public var activeMinutes: Int { Int((activeSeconds / 60).rounded()) }
  /// Switches per active hour, one decimal: switches ÷ active minutes × 60, so the arithmetic line reproduces it
  /// (review 1, finding 8).
  public var switchesPerHour: Double {
    activeMinutes > 0 ? (Double(switches) / Double(activeMinutes) * 60 * 10).rounded() / 10 : 0
  }

  public var activeEvidence: [EvidenceRef] { Self.dedupe(days.flatMap(\.activeSeconds.evidence)) }
  public var focusEvidence: [EvidenceRef] { Self.dedupe(days.flatMap(\.focusSeconds.evidence)) }
  public var switchEvidence: [EvidenceRef] { Self.dedupe(days.flatMap(\.switches.evidence)) }

  public static func hours(_ seconds: TimeInterval) -> Double { (seconds / 360).rounded() / 10 }

  /// Weeks with data, oldest first.
  public static func weeks(_ days: [DayInsights], timeZone: TimeZone) -> [WeekStats] {
    var byWeek: [String: WeekStats] = [:]
    for d in days where !d.isEmpty {
      guard let start = LocalDays.start(of: d.day, timeZone: timeZone) else { continue }
      let w = ISOWeek(containing: start, timeZone: timeZone)
      byWeek[w.id, default: WeekStats(week: w, days: [])].days.append(d)
    }
    return byWeek.values
      .map { WeekStats(week: $0.week, days: $0.days.sorted { $0.day < $1.day }) }
      .sorted { $0.week < $1.week }
  }

  /// A repeat's minutes in `week`: its occurrences that start in the week.
  public static func minutes(of pattern: RepeatPattern, in week: ISOWeek) -> Int {
    Int((occurrences(of: pattern, in: week).reduce(0) { $0 + $1.seconds } / 60).rounded())
  }

  public static func occurrences(of pattern: RepeatPattern, in week: ISOWeek) -> [RepeatOccurrence] {
    pattern.occurrences.filter { week.contains($0.start) }
  }

  /// The weeks with data in a row (no gap) that end at `week`, oldest first; empty when `week` has no data.
  public static func chain(_ history: [WeekStats], endingAt week: ISOWeek) -> [WeekStats] {
    var byID: [String: WeekStats] = [:]
    for h in history where h.hasData { byID[h.week.id] = h }
    var out: [WeekStats] = []
    var cursor = week
    while let h = byID[cursor.id] {
      out.insert(h, at: 0)
      cursor = cursor.previous
    }
    return out
  }

  /// The changes in a row at the end of `values` that go the same way: +3 for three rises, −2 for two falls, 0 when the
  /// last two are equal or there are fewer than two values.
  public static func run(_ values: [Double]) -> Int {
    guard values.count >= 2 else { return 0 }
    let last = values.count - 1
    let way = sign(values[last] - values[last - 1])
    guard way != 0 else { return 0 }
    var n = 0
    var i = last
    while i > 0, sign(values[i] - values[i - 1]) == way {
      n += 1
      i -= 1
    }
    return way * n
  }

  /// The median, one decimal; nil for none.
  public static func median(_ values: [Double]) -> Double? {
    let s = values.sorted()
    guard !s.isEmpty else { return nil }
    let mid = s.count / 2
    let m = s.count % 2 == 1 ? s[mid] : (s[mid - 1] + s[mid]) / 2
    return (m * 10).rounded() / 10
  }

  static func sign(_ v: Double) -> Int { v > 1e-9 ? 1 : (v < -1e-9 ? -1 : 0) }

  static func dedupe(_ refs: [EvidenceRef]) -> [EvidenceRef] {
    var seen = Set<EvidenceRef>()
    return refs.filter { seen.insert($0).inserted }
  }
}

/// Goals as the review keeps them on this Mac.
public enum ReviewGoals {
  /// `g_` + first 10 hex of SHA-256 of the goal text, trimmed and lowercased (the brain's id shape; the brain also
  /// hashes its `created_at`, which the Mac does not have).
  public static func id(_ text: String) -> String {
    let normal = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    let digest = SHA256.hash(data: Data(normal.utf8))
    return "g_" + String(digest.map { String(format: "%02x", $0) }.joined().prefix(10))
  }
}
