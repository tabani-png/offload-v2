import Foundation

// ISO 8601 weeks in the person's time zone (SPEC m3-12 Contract): Monday first, week 1 is the week that holds
// 4 January. A week is built from that Monday plus whole calendar days, so it stays Monday midnight to Monday midnight
// across daylight saving changes.

public struct ISOWeek: Hashable, Comparable, Sendable, CustomStringConvertible {
  public let year: Int
  public let week: Int
  public let timeZone: TimeZone

  /// "2026-W47"; nil for anything that is not a week of that year ("2027-W53", "2026-W00", "2026-47").
  public init?(_ id: String, timeZone: TimeZone) {
    guard APIClientCore.isISOWeek(id), let y = Int(id.prefix(4)), let w = Int(id.suffix(2)), (1...53).contains(w) else {
      return nil
    }
    year = y
    week = w
    self.timeZone = timeZone
    // Week 53 exists only in some years: the week must read back as itself.
    guard ISOWeek(containing: from, timeZone: timeZone).id == id else { return nil }
  }

  /// The week that holds `date` in `timeZone`.
  public init(containing date: Date, timeZone: TimeZone) {
    var cal = Calendar(identifier: .iso8601)
    cal.timeZone = timeZone
    let c = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
    year = c.yearForWeekOfYear ?? 1970
    week = c.weekOfYear ?? 1
    self.timeZone = timeZone
  }

  /// "2026-W47".
  public var id: String { Self.pad(year, 4) + "-W" + Self.pad(week, 2) }
  public var description: String { id }

  /// Monday 00:00 of the week.
  public var from: Date {
    let cal = LocalDays.calendar(timeZone)
    guard let jan4 = cal.date(from: DateComponents(year: year, month: 1, day: 4)) else { return Date(timeIntervalSince1970: 0) }
    // Calendar weekday: Sunday 1 … Saturday 7; days back to Monday: Monday 0 … Sunday 6.
    let back = (cal.component(.weekday, from: jan4) + 5) % 7
    let monday = cal.date(byAdding: .day, value: -back + (week - 1) * 7, to: jan4) ?? jan4
    return cal.startOfDay(for: monday)
  }

  /// The next Monday 00:00 (the end, not included).
  public var to: Date { day(7) }

  public var next: ISOWeek { ISOWeek(containing: day(7), timeZone: timeZone) }
  public var previous: ISOWeek { ISOWeek(containing: day(-7), timeZone: timeZone) }

  public func contains(_ date: Date) -> Bool { date >= from && date < to }

  /// The seven days, "2026-11-16" … "2026-11-22".
  public var dayLabels: [String] { (0..<7).map { LocalDays.label(day($0), timeZone: timeZone) } }

  /// Midnight `offset` days after Monday.
  func day(_ offset: Int) -> Date {
    let cal = LocalDays.calendar(timeZone)
    let start = from
    return cal.startOfDay(for: cal.date(byAdding: .day, value: offset, to: start) ?? start)
  }

  public static func < (a: ISOWeek, b: ISOWeek) -> Bool { a.year != b.year ? a.year < b.year : a.week < b.week }

  static func pad(_ n: Int, _ width: Int) -> String {
    let s = String(n)
    return s.count >= width ? s : String(repeating: "0", count: width - s.count) + s
  }
}
