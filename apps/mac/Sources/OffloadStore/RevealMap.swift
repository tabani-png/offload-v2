// The reveal map (ADR 0028, C0): pseudonym -> the value it stands for, on this Mac only, kept 7 days and never uploaded.
// The UI shows real names from it; after 7 days a pseudonym is "seen before last week".
import CryptoKit
import Foundation
import OffloadContracts

public final class RevealMap: @unchecked Sendable {
    private struct Entry: Codable {
        var value: String
        /// Local day the pseudonym was last seen.
        var day: String
    }

    private let layout: StoreLayout
    private let keys: KeyRing
    private let days: DayCalendar
    private let lock = NSLock()
    private var entries: [String: Entry]?

    public init(layout: StoreLayout, keys: KeyRing, days: DayCalendar = DayCalendar()) {
        self.layout = layout
        self.keys = keys
        self.days = days
    }

    private func load() -> [String: Entry] {
        if let entries { return entries }
        var loaded: [String: Entry] = [:]
        if let key = try? keys.stateKey("reveal"), let plain = try? SealedFile.read(layout.revealFile, key: key),
           let decoded = try? JSONDecoder().decode([String: Entry].self, from: plain) {
            loaded = decoded
        }
        entries = loaded
        return loaded
    }

    private func save(_ map: [String: Entry]) throws {
        entries = map
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try SealedFile.write(try encoder.encode(map), to: layout.revealFile, key: try keys.stateKey("reveal"), layout: layout)
    }

    /// Remembers `values` (pseudonym -> value) as seen at `date`.
    public func record(_ values: [String: String], at date: Date) throws {
        guard !values.isEmpty else { return }
        try lock.withLock {
            var map = load()
            let day = days.day(of: date)
            for (pseudonym, value) in values { map[pseudonym] = Entry(value: value, day: day) }
            try save(map)
        }
    }

    /// The value a pseudonym stands for, or nil (never seen, or older than 7 days).
    public func resolve(_ pseudonym: String) -> String? { lock.withLock { load()[pseudonym]?.value } }

    /// Forgets entries last seen more than 7 days ago. Returns how many.
    @discardableResult
    public func purge(now: Date, keepDays: Int = Retention.defaultKeepDays) throws -> Int {
        try lock.withLock {
            var map = load()
            let before = map.count
            map = map.filter { _, entry in (days.age(ofDay: entry.day, now: now) ?? 0) <= keepDays }
            guard map.count != before else { return 0 }
            try save(map)
            return before - map.count
        }
    }
}
