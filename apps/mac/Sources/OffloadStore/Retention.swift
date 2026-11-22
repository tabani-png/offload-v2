// Seven days, purged hourly: a day is deleted (file and key) when its local age is more than 7 days, so today and the
// 7 days before it are kept. Every deletion writes one line to `purge-log.jsonl`: day, domain, count, never content.
import Foundation
import OffloadContracts

public struct PurgeRecord: Codable, Equatable, Sendable {
    /// `days` (observations) or `egress` (the ledger).
    public var domain: String
    public var day: String
    /// Unix epoch milliseconds.
    public var deletedAt: Int64
    /// Lines the deleted file held.
    public var records: Int

    enum CodingKeys: String, CodingKey {
        case domain, day
        case deletedAt = "deleted_at"
        case records
    }
}

public struct Retention: Sendable {
    public static let defaultKeepDays = 7

    public let layout: StoreLayout
    public let days: DayCalendar
    public let keepDays: Int

    public init(layout: StoreLayout, days: DayCalendar = DayCalendar(), keepDays: Int = Retention.defaultKeepDays) {
        self.layout = layout
        self.days = days
        self.keepDays = keepDays
    }

    /// Stored day names of one domain (from its files and key files), sorted.
    public func storedDays(domain: KeyDomain) -> [String] {
        var names = Set<String>()
        for entry in (try? FileManager.default.contentsOfDirectory(atPath: layout.directory(for: domain).path)) ?? [] where entry.hasSuffix(".jsonl.enc") {
            let day = String(entry.dropLast(".jsonl.enc".count))
            if DayCalendar.isDayName(day) { names.insert(day) }
        }
        return names.sorted()
    }

    /// Deletes every expired day of every domain and appends one purge-log line per day. Returns the records written.
    @discardableResult
    public func purge(now: Date) throws -> [PurgeRecord] {
        try FileGate.lock.withLock {
            var records: [PurgeRecord] = []
            for domain in KeyDomain.allCases {
                var names = Set(storedDays(domain: domain))
                // A key file left without its data file is expired too.
                let prefix = "\(domain.rawValue)-"
                for entry in (try? FileManager.default.contentsOfDirectory(atPath: layout.keysDir.path)) ?? [] where entry.hasPrefix(prefix) && entry.hasSuffix(".key") {
                    let day = String(entry.dropFirst(prefix.count).dropLast(".key".count))
                    if DayCalendar.isDayName(day) { names.insert(day) }
                }
                for day in names.sorted() {
                    guard let age = days.age(ofDay: day, now: now), age > keepDays else { continue }
                    let data = layout.file(for: domain, day: day)
                    let count = SealedLines.lineCount(data)
                    var ok = true
                    for url in [data, layout.keyFile(domain: domain, day: day)] where FileManager.default.fileExists(atPath: url.path) {
                        do { try FileManager.default.removeItem(at: url) } catch { ok = false }
                    }
                    guard ok else { continue }
                    let record = PurgeRecord(domain: domain.rawValue, day: day, deletedAt: Timestamp.millis(now), records: count)
                    records.append(record)
                    try appendLog(record)
                }
            }
            return records
        }
    }

    private func appendLog(_ record: PurgeRecord) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let line = try encoder.encode(record) + Data("\n".utf8)
        try layout.ensureDirectories()
        if !FileManager.default.fileExists(atPath: layout.purgeLog.path) {
            guard FileManager.default.createFile(atPath: layout.purgeLog.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw StoreError.io("create purge-log.jsonl")
            }
        }
        let handle = try FileHandle(forWritingTo: layout.purgeLog)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: line)
    }
}
