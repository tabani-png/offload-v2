import Foundation

// When the weekly review lands (SPEC m3-12 Contract): the review slot, where it is kept on this Mac, and the schedule
// rules (the next slot, and which week the screen shows).

extension Weekday {
  /// Days after Monday: Monday 0 … Sunday 6.
  var daysFromMonday: Int { Weekday.allCases.firstIndex(of: self) ?? 0 }
  /// Calendar weekday: Sunday 1 … Saturday 7.
  var calendarWeekday: Int { self == .sun ? 1 : daysFromMonday + 2 }
}

/// A day and an "HH:mm" time, as kept on this Mac.
public struct ReviewSlotChoice: Equatable, Sendable {
  public var day: Weekday
  public var time: String

  public init(day: Weekday, time: String) {
    self.day = day
    self.time = time
  }
}

public struct ReviewSlot: Equatable, Sendable {
  public var day: Weekday
  /// 24-hour "HH:mm".
  public var time: String
  public var timeZone: TimeZone

  public init(day: Weekday = .fri, time: String = "16:00", timeZone: TimeZone = .current) {
    self.day = day
    self.time = time
    self.timeZone = timeZone
  }

  /// The brain profile's `review_slot` (`{ day: "fri", time: "16:00" }`); nil for words or times it cannot hold.
  public init?(brain: BrainReviewSlot, timeZone: TimeZone) {
    guard let day = Weekday(rawValue: brain.day), Self.parse(brain.time) != nil else { return nil }
    self.init(day: day, time: brain.time, timeZone: timeZone)
  }

  public var brain: BrainReviewSlot { BrainReviewSlot(day: day.rawValue, time: time) }

  public var hour: Int { Self.parse(time)?.hour ?? 16 }
  public var minute: Int { Self.parse(time)?.minute ?? 0 }

  /// "Fri 4:00 PM".
  public var text: String { "\(day.short) \(Rhythm.clock(time))" }
  /// "Friday at 4:00 PM".
  public var long: String { "\(day.full) at \(Rhythm.clock(time))" }

  /// Exactly "HH:mm", 00:00 to 23:59.
  public static func parse(_ hhmm: String) -> (hour: Int, minute: Int)? {
    let parts = hhmm.split(separator: ":", omittingEmptySubsequences: false)
    guard parts.count == 2, parts[0].count == 2, parts[1].count == 2,
          parts.allSatisfy({ $0.allSatisfy { $0.isASCII && $0.isNumber } }),
          let h = Int(parts[0]), let m = Int(parts[1]), (0..<24).contains(h), (0..<60).contains(m) else { return nil }
    return (h, m)
  }

  /// "09:05" from hour and minute.
  public static func time(hour: Int, minute: Int) -> String {
    (hour < 10 ? "0\(hour)" : "\(hour)") + ":" + (minute < 10 ? "0\(minute)" : "\(minute)")
  }

  /// The slot kept on this Mac, else the rhythm answered in onboarding (m3-04), else Friday 16:00.
  public static func resolve(store: (any ReviewSettingsStore)?, rhythm: Rhythm?, timeZone: TimeZone) -> ReviewSlot {
    if let c = store?.storedSlot(), parse(c.time) != nil { return ReviewSlot(day: c.day, time: c.time, timeZone: timeZone) }
    if let r = rhythm, parse(r.reviewTime) != nil { return ReviewSlot(day: r.reviewDay, time: r.reviewTime, timeZone: timeZone) }
    return ReviewSlot(day: .fri, time: "16:00", timeZone: timeZone)
  }
}

/// Where the review settings are kept on this Mac: the slot (in `.local`) and the notification toggle (both modes).
public protocol ReviewSettingsStore: AnyObject {
  func storedSlot() -> ReviewSlotChoice?
  func saveSlot(day: Weekday, time: String)
  var notify: Bool { get set }
  /// The review screen's notification offer was answered (accepted or declined) or the toggle was used.
  var offerDone: Bool { get set }
}

public final class MemoryReviewSettingsStore: ReviewSettingsStore {
  private var slot: ReviewSlotChoice?
  public var notify: Bool
  public var offerDone: Bool

  public init(slot: ReviewSlotChoice? = nil, notify: Bool = false, offerDone: Bool = false) {
    self.slot = slot
    self.notify = notify
    self.offerDone = offerDone
  }

  public func storedSlot() -> ReviewSlotChoice? { slot }
  public func saveSlot(day: Weekday, time: String) { slot = ReviewSlotChoice(day: day, time: time) }
}

/// `UserDefaults`: `ai.offload.review.day` (`mon` … `sun`), `ai.offload.review.time` ("HH:mm"),
/// `ai.offload.review.notify`, `ai.offload.review.offered`.
public final class UserDefaultsReviewSettingsStore: ReviewSettingsStore {
  public static let dayKey = "ai.offload.review.day"
  public static let timeKey = "ai.offload.review.time"
  public static let notifyKey = "ai.offload.review.notify"
  public static let offeredKey = "ai.offload.review.offered"

  private let defaults: UserDefaults

  public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

  public func storedSlot() -> ReviewSlotChoice? {
    guard let raw = defaults.string(forKey: Self.dayKey), let day = Weekday(rawValue: raw),
          let time = defaults.string(forKey: Self.timeKey), ReviewSlot.parse(time) != nil else { return nil }
    return ReviewSlotChoice(day: day, time: time)
  }

  public func saveSlot(day: Weekday, time: String) {
    defaults.set(day.rawValue, forKey: Self.dayKey)
    defaults.set(time, forKey: Self.timeKey)
  }

  public var notify: Bool {
    get { defaults.bool(forKey: Self.notifyKey) }
    set { defaults.set(newValue, forKey: Self.notifyKey) }
  }

  public var offerDone: Bool {
    get { defaults.bool(forKey: Self.offeredKey) }
    set { defaults.set(newValue, forKey: Self.offeredKey) }
  }
}

public enum ReviewSchedule {
  /// The slot's moment in `week` (the week's Monday plus the slot's days, at its local time).
  public static func date(of slot: ReviewSlot, in week: ISOWeek) -> Date {
    let cal = LocalDays.calendar(slot.timeZone)
    let day = ISOWeek(containing: week.from, timeZone: slot.timeZone).day(slot.day.daysFromMonday)
    return cal.date(bySettingHour: slot.hour, minute: slot.minute, second: 0, of: day) ?? day
  }

  /// The first slot strictly after `date`.
  public static func next(after date: Date, slot: ReviewSlot) -> Date {
    let week = ISOWeek(containing: date, timeZone: slot.timeZone)
    let here = self.date(of: slot, in: week)
    return here > date ? here : self.date(of: slot, in: week.next)
  }

  /// The week that holds `now`.
  public static func currentWeek(now: Date, slot: ReviewSlot) -> ISOWeek {
    ISOWeek(containing: now, timeZone: slot.timeZone)
  }

  /// This week once its slot has passed, else last week.
  public static func shownWeek(now: Date, slot: ReviewSlot) -> ISOWeek {
    let current = currentWeek(now: now, slot: slot)
    return now >= date(of: slot, in: current) ? current : current.previous
  }

  /// True for the current week before its slot, and for any later week.
  public static func isNotYet(_ week: ISOWeek, now: Date, slot: ReviewSlot) -> Bool {
    let current = currentWeek(now: now, slot: slot)
    if current < week { return true }
    return week.id == current.id && now < date(of: slot, in: current)
  }
}
