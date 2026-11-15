// The local egress ledger (ADR 0035): every uploaded batch, sealed, kept 7 days, shown in the app as "What was sent".
// One record per batch: time, destination, kind, object count, bytes, counts by detector, and the exact bytes that left.
import Foundation
import OffloadContracts

public struct EgressRecord: Codable, Equatable, Sendable {
    public var time: String
    public var destination: String
    public var kind: String
    public var objectCount: Int
    public var bytes: Int
    /// Hits per device detector on this batch (zero for a batch that left: a hit stops it).
    public var detectors: [String: Int]
    /// Pseudonyms in the batch, by kind: what the masker replaced.
    public var pseudonyms: [String: Int]
    /// The exact bytes sent (the signed JCS body).
    public var body: Data

    public init(time: String, destination: String, kind: String, objectCount: Int, bytes: Int, detectors: [String: Int], pseudonyms: [String: Int], body: Data) {
        self.time = time
        self.destination = destination
        self.kind = kind
        self.objectCount = objectCount
        self.bytes = bytes
        self.detectors = detectors
        self.pseudonyms = pseudonyms
        self.body = body
    }

    enum CodingKeys: String, CodingKey {
        case time, destination, kind
        case objectCount = "object_count"
        case bytes, detectors, pseudonyms, body
    }
}

public final class EgressLedger: @unchecked Sendable {
    private let layout: StoreLayout
    private let keys: KeyRing
    private let days: DayCalendar

    public init(layout: StoreLayout, keys: KeyRing, days: DayCalendar = DayCalendar()) {
        self.layout = layout
        self.keys = keys
        self.days = days
    }

    public func append(_ record: EgressRecord) throws {
        guard let date = Timestamp.parse(record.time) else { throw StoreError.badLine(0) }
        let day = days.day(of: date)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = try encoder.encode(record)
        try FileGate.lock.withLock {
            let key = try keys.dayKey(domain: .egress, day: day, create: true)
            try SealedLines.append(json, to: layout.egressFile(day), key: key, layout: layout)
        }
    }

    public func read(day: String) throws -> [EgressRecord] {
        guard DayCalendar.isDayName(day) else { throw StoreError.invalidDay(day) }
        return try FileGate.lock.withLock {
            let url = layout.egressFile(day)
            guard FileManager.default.fileExists(atPath: url.path) else { return [] }
            let key = try keys.dayKey(domain: .egress, day: day, create: false)
            return try SealedLines.read(url, key: key).enumerated().map { n, line in
                do { return try JSONDecoder().decode(EgressRecord.self, from: line) } catch { throw StoreError.badLine(n + 1) }
            }
        }
    }

    /// Days that have a ledger, oldest first.
    public func storedDays() -> [String] { Retention(layout: layout, days: days).storedDays(domain: .egress) }
}
