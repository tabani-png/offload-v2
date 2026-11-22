// Time seams and formats shared by the Mac targets. `Clock` is the standard library's name, so ours is `TimeSource`.
import Foundation

public protocol TimeSource: AnyObject, Sendable {
    var now: Date { get }
}

public final class SystemTime: TimeSource {
    public init() {}
    public var now: Date { Date() }
}

/// A clock tests move by hand.
public final class ManualTime: TimeSource, @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    public init(_ start: Date) { current = start }

    public var now: Date { lock.withLock { current } }

    public func advance(by seconds: TimeInterval) { lock.withLock { current = current.addingTimeInterval(seconds) } }

    public func set(_ date: Date) { lock.withLock { current = date } }
}

/// RFC 3339 timestamps as the ingest contract writes them: UTC, millisecond precision, `Z`.
public enum Timestamp {
    public static func format(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: date)
    }

    public static func parse(_ text: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: text) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: text)
    }

    public static func millis(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 * 1000).rounded(.down)) }
}

/// Local-day naming `YYYY-MM-DD` in a time zone (the day files and the egress ledger are named by it).
public struct DayCalendar: Sendable {
    public let calendar: Calendar

    public init(timeZone: TimeZone = .current) {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = timeZone
        calendar = c
    }

    public func day(of date: Date) -> String {
        let d = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", d.year ?? 0, d.month ?? 0, d.day ?? 0)
    }

    /// Start of the named day, or nil when `day` is not a real `YYYY-MM-DD`.
    public func date(ofDay day: String) -> Date? {
        let parts = day.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]) else { return nil }
        var comps = DateComponents()
        comps.year = y
        comps.month = m
        comps.day = d
        guard let date = calendar.date(from: comps), self.day(of: date) == day else { return nil }
        return date
    }

    /// Whole local days from `day` to the day of `now` (0 = today); nil for an invalid day name.
    public func age(ofDay day: String, now: Date) -> Int? {
        guard let start = date(ofDay: day) else { return nil }
        return calendar.dateComponents([.day], from: start, to: calendar.startOfDay(for: now)).day
    }

    public static func isDayName(_ s: String) -> Bool {
        let chars = Array(s)
        guard chars.count == 10, chars[4] == "-", chars[7] == "-" else { return false }
        return chars.enumerated().allSatisfy { i, c in i == 4 || i == 7 || (c.isASCII && c.isNumber) }
    }
}
