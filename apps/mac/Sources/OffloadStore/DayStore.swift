// The encrypted 7-day buffer: `days/YYYY-MM-DD.jsonl.enc`, one sealed JSON line per observation, one key per day.
// The observer only appends; the uploader only reads.
import Foundation
import OffloadContracts

/// Where observations go. The observer only appends.
public protocol ObservationSink: AnyObject {
    func append(_ observation: Observation) throws
}

public final class DayStore: ObservationSink, @unchecked Sendable {
    public let layout: StoreLayout
    public let keys: KeyRing
    public let days: DayCalendar

    public init(layout: StoreLayout, keys: KeyRing, days: DayCalendar = DayCalendar()) {
        self.layout = layout
        self.keys = keys
        self.days = days
    }

    /// The day an observation belongs to, from its `ts`.
    public func day(of observation: Observation) throws -> String {
        guard let date = Timestamp.parse(observation.ts) else { throw StoreError.badLine(0) }
        return days.day(of: date)
    }

    public func append(_ observation: Observation) throws {
        let day = try day(of: observation)
        let json: Data
        do { json = try JSONEncoder().encode(observation) } catch { throw StoreError.io("encode \(observation.id)") }
        try FileGate.lock.withLock {
            let key = try keys.dayKey(domain: .days, day: day, create: true)
            try SealedLines.append(json, to: layout.dayFile(day), key: key, layout: layout)
        }
    }

    /// Every observation of `day`, in file order. A day with no file is empty.
    public func read(day: String) throws -> [Observation] {
        guard DayCalendar.isDayName(day), days.date(ofDay: day) != nil else { throw StoreError.invalidDay(day) }
        return try FileGate.lock.withLock {
            let url = layout.dayFile(day)
            guard FileManager.default.fileExists(atPath: url.path) else { return [] }
            let key = try keys.dayKey(domain: .days, day: day, create: false)
            let lines = try SealedLines.read(url, key: key)
            return try lines.enumerated().map { n, line in
                do { return try JSONDecoder().decode(Observation.self, from: line) } catch { throw StoreError.badLine(n + 1) }
            }
        }
    }

    /// Stored day names, oldest first.
    public func storedDays() -> [String] { Retention(layout: layout, days: days).storedDays(domain: .days) }
}
