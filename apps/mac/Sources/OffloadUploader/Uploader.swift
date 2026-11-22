// The uploader: the Mac's egress guard (ADR 0035, ADR 0020). It reads observations the observer wrote, builds signed
// envelopes only from the generated closed types, runs the device detectors again on every object, and sends to one host.
// `seq` and each pending batch's exact bytes are persisted BEFORE the send, so a restart resends identical bytes and seq.
// Any error before a send means nothing is sent (fail closed). Flush every 300 s and on quit; back off up to 6 hours.
import Foundation
import OffloadContracts
import OffloadMasker
import OffloadStore

public struct UploaderConfig: Sendable {
    public var apiBase: URL
    public var deviceID: String
    public var flushSeconds: TimeInterval
    public var maxObjects: Int
    public var maxBytes: Int
    public var keepDays: Int

    public init(apiBase: URL, deviceID: String, flushSeconds: TimeInterval = 300, maxObjects: Int = 500, maxBytes: Int = 1_048_576, keepDays: Int = 7) {
        self.apiBase = apiBase
        self.deviceID = deviceID
        self.flushSeconds = flushSeconds
        self.maxObjects = maxObjects
        self.maxBytes = maxBytes
        self.keepDays = keepDays
    }
}

public struct FlushReport: Equatable, Sendable {
    public var sentBatches = 0
    public var sentObjects = 0
    public var droppedOld = 0
    public var blocked = 0
    public var failed = false

    public init() {}
}

public actor Uploader {
    public let config: UploaderConfig
    private let transport: GuardedTransport
    private let egress: EgressGuard
    private let signer: any DeviceSigner
    private let tokens: any TokenProvider
    private let store: DayStore
    private let stateStore: UploadStateStore
    private let ledger: EgressLedger
    private let time: any TimeSource
    private var lastFlush: Date?
    /// Recordings-import objects staged on this Mac (m3-14), batched by the next flush. Nil: no imports.
    private let importOutbox: ImportOutbox?

    public init(config: UploaderConfig, transport: any HTTPTransport, signer: any DeviceSigner, tokens: any TokenProvider, store: DayStore,
                state: UploadStateStore, ledger: EgressLedger, time: any TimeSource, importOutbox: ImportOutbox? = nil) {
        self.config = config
        egress = EgressGuard(apiBase: config.apiBase)
        self.transport = GuardedTransport(inner: transport, guard: egress)
        self.signer = signer
        self.tokens = tokens
        self.store = store
        stateStore = state
        self.ledger = ledger
        self.time = time
        self.importOutbox = importOutbox
    }

    /// The counters the app shows (read from the persisted state, so they survive a restart).
    public var counters: UploadCounters { (try? stateStore.load())?.counters ?? UploadCounters() }

    /// Back-off after `streak` failed flushes in a row: 5 minutes, doubling, at most 6 hours.
    static func backoff(streak: Int) -> TimeInterval { min(21_600, 300 * pow(2, Double(max(0, streak - 1)))) }

    /// The scheduled call: flushes when 300 s have passed and the back-off allows it; nil when it did nothing.
    public func tick() async -> FlushReport? {
        let now = time.now
        if let last = lastFlush, now.timeIntervalSince(last) < config.flushSeconds { return nil }
        if let state = try? stateStore.load(), let retry = state.retryAfter, now.timeIntervalSince1970 < retry { return nil }
        return await flush()
    }

    /// Batches what is new, then sends every pending batch in seq order. Also what quitting the app calls.
    public func flush() async -> FlushReport {
        var report = FlushReport()
        let now = time.now
        lastFlush = now
        var state: UploadState
        do { state = try stateStore.load() } catch { report.failed = true; return report }

        do {
            let blocked = try build(&state, &report, now: now)
            // Staged import objects join the queue in the same step, before any send (no suspension in between).
            let drained: Set<String> = try blocked ? [] : batchStagedImports(&state, &report, now: now)
            try stateStore.save(state)
            // Removed only once the batches holding them are saved: at worst an object is queued twice, never lost.
            if !drained.isEmpty { try? importOutbox?.remove(ids: drained) }
            if blocked { report.failed = true; return report }
        } catch {
            report.failed = true
            return report
        }

        var rebatchedOnce = false
        while let batch = state.pending.first {
            let outcome = await send(batch, state: &state, now: now, allowRebatch: !rebatchedOnce)
            switch outcome {
            case .sent(let sent):
                state.pending.removeFirst()
                state.counters.sentBatches += 1
                state.counters.sentObjects += sent.objectCount
                state.failureStreak = 0
                state.retryAfter = nil
                report.sentBatches += 1
                report.sentObjects += sent.objectCount
                try? stateStore.save(state)
            case .rebatched(let replacement):
                rebatchedOnce = true
                state.pending[0] = replacement
                state.counters.rebatched += 1
                try? stateStore.save(state)
            case .failed:
                state.counters.failures += 1
                state.failureStreak += 1
                state.retryAfter = now.timeIntervalSince1970 + Self.backoff(streak: state.failureStreak)
                try? stateStore.save(state)
                report.failed = true
                return report
            }
        }
        return report
    }

    // MARK: building

    /// Reads what the observer wrote after the last batched id. Returns true when a detector stopped something: nothing
    /// is batched or sent in that flush, the offending objects are set aside, and the next flush carries on without them.
    private func build(_ state: inout UploadState, _ report: inout FlushReport, now: Date) throws -> Bool {
        let all = try unsent(after: state.batchedThrough, skipping: Set(state.quarantined))
        guard let newest = all.last?.id else { return false }
        let cutoff = now.addingTimeInterval(-Double(config.keepDays) * 86_400)
        var fresh: [Observation] = []
        var dropped = 0
        for o in all {
            if let ts = Timestamp.parse(o.ts), ts < cutoff { dropped += 1 } else { fresh.append(o) }
        }
        var blocked = 0
        for o in fresh {
            do { try egress.inspect(o) } catch {
                state.quarantined.append(o.id)
                blocked += 1
            }
        }
        if blocked > 0 {
            state.counters.blocked += blocked
            report.blocked = blocked
            return true
        }
        state.counters.droppedOld += dropped
        report.droppedOld = dropped

        var index = 0
        while index < fresh.count {
            var n = min(config.maxObjects, fresh.count - index)
            var body = try envelope(Array(fresh[index..<index + n]), seq: state.nextSeq, now: now)
            while body.count > config.maxBytes, n > 1 {
                n = max(1, n * 2 / 3)
                body = try envelope(Array(fresh[index..<index + n]), seq: state.nextSeq, now: now)
            }
            state.pending.append(PendingBatch(seq: state.nextSeq, body: body, lastId: fresh[index + n - 1].id, objectCount: n, kind: "observation_batch"))
            state.nextSeq += 1
            index += n
        }
        state.batchedThrough = newest
        return false
    }

    private func envelope(_ objects: [Observation], seq: Int, now: Date) throws -> Data {
        let batch = IngestEnvelope.observationBatch(IngestEnvelopeObservationBatch(
            deviceId: config.deviceID, seq: seq, sentAt: Timestamp.format(now), objects: objects))
        let body = try JCS.encode(batch)
        // The bytes must survive the closed schema they were built from.
        do { _ = try JSONDecoder().decode(IngestEnvelope.self, from: body) } catch { throw EgressError.invalidEnvelope }
        return body
    }

    /// New objects by id order: only the day files that can hold ids after the cursor are opened.
    private func unsent(after cursor: String?, skipping quarantined: Set<String>) throws -> [Observation] {
        var firstDay: String?
        if let cursor, let ms = ULIDGenerator.millis(of: cursor) {
            firstDay = store.days.day(of: Date(timeIntervalSince1970: TimeInterval(ms) / 1000 - 86_400))
        }
        var out: [Observation] = []
        for day in store.storedDays() where firstDay.map({ day >= $0 }) ?? true {
            for o in try store.read(day: day) where !quarantined.contains(o.id) && (cursor.map { o.id > $0 } ?? true) { out.append(o) }
        }
        return out.sorted { $0.id < $1.id }
    }

    // MARK: sending

    private enum Outcome {
        case sent(PendingBatch)
        case rebatched(PendingBatch)
        case failed
    }

    private func send(_ batch: PendingBatch, state: inout UploadState, now: Date, allowRebatch: Bool) async -> Outcome {
        guard let first = await attempt(batch) else { return .failed }
        switch first {
        case .receipt:
            record(batch, now: now)
            return .sent(batch)
        case .replay:
            // A seq the server already knows: send the same bytes again; a stored batch with these bytes answers with its receipt.
            guard let second = await attempt(batch) else { return .failed }
            if case .receipt = second {
                record(batch, now: now)
                return .sent(batch)
            }
            guard allowRebatch, case .replay = second, let remade = try? rebatch(batch, seq: state.nextSeq, now: now) else { return .failed }
            state.nextSeq += 1
            return .rebatched(remade)
        case .rejected:
            return .failed
        }
    }

    private enum Attempt {
        case receipt
        case replay
        case rejected
    }

    /// One POST of the exact stored bytes. Nil when the request could not be made or the answer is not usable.
    private func attempt(_ batch: PendingBatch) async -> Attempt? {
        do {
            var refreshed = false
            while true {
                let token = try await tokens.token(forceRefresh: refreshed)
                let signature = Base64URL.encode(try signer.sign(batch.body))
                let request = HTTPRequest(
                    url: config.apiBase.appendingPathComponent("v1/ingest/batches"), method: "POST",
                    headers: [
                        "Authorization": "Bearer \(token)", "Content-Type": "application/json",
                        "Offload-Signature": "keyid=\(config.deviceID), sig=\(signature)",
                    ], body: batch.body)
                let response = try await transport.send(request)
                switch response.status {
                case 200:
                    _ = try JSONDecoder().decode(IngestReceipt.self, from: response.body)
                    return .receipt
                case 401 where !refreshed:
                    refreshed = true
                    continue
                case 409:
                    if let e = try? JSONDecoder().decode(ErrorEnvelope.self, from: response.body), e.error.code.rawValue == "seq_replay" { return .replay }
                    return .rejected
                default:
                    return .rejected
                }
            }
        } catch {
            return nil
        }
    }

    /// The same objects under a new seq (a conflict that identical bytes did not clear is a client bug).
    private func rebatch(_ batch: PendingBatch, seq: Int, now: Date) throws -> PendingBatch {
        guard case .observationBatch(let old) = try JSONDecoder().decode(IngestEnvelope.self, from: batch.body) else { throw EgressError.invalidEnvelope }
        let body = try envelope(old.objects, seq: seq, now: now)
        return PendingBatch(seq: seq, body: body, lastId: batch.lastId, objectCount: batch.objectCount, kind: batch.kind)
    }

    /// One sealed ledger line with the exact bytes that left.
    private func record(_ batch: PendingBatch, now: Date) {
        var objects: [Observation] = []
        if case .observationBatch(let b)? = try? JSONDecoder().decode(IngestEnvelope.self, from: batch.body) { objects = b.objects }
        let summary = egress.summary(of: objects)
        let entry = EgressRecord(
            time: Timestamp.format(now), destination: egress.host, kind: batch.kind, objectCount: batch.objectCount,
            bytes: batch.body.count, detectors: summary.detectors, pseudonyms: summary.pseudonyms, body: batch.body)
        try? ledger.append(entry)
    }
}

// MARK: - import spaces (slice m3-14-mac-app-integration)
//
// A recordings import (m3-05) leaves the Mac only through this uploader (ADR 0035). The import space is opened and
// forgotten with signed requests to the one API host, each written to the egress ledger. Its objects are staged on
// this Mac first (ImportOutbox: checked, sealed, durable) and batched by the next flush as ordinary observation batches
// under the next seqs, with the detectors run again and the same retry as live batches.

public enum ImportUploadError: Error, Equatable, Sendable {
    /// The server answered with this status.
    case rejected(status: Int)
    /// A 2xx answer without the expected body.
    case badAnswer
    /// An object that is not `source = "import"` with an `import_id`.
    case notAnImportObject
}

extension Uploader {
    /// `POST /v1/imports` with `{ source_kind }`; returns the new space's `import_id`.
    public func openImport(sourceKind: String) async throws -> String {
        let body = try Self.requestBody(["source_kind": sourceKind])
        let response = try await signedPost("v1/imports", body: body)
        guard response.status == 200 || response.status == 201 else { throw ImportUploadError.rejected(status: response.status) }
        struct Created: Decodable {
            let importID: String
            enum CodingKeys: String, CodingKey { case importID = "import_id" }
        }
        guard let created = try? JSONDecoder().decode(Created.self, from: response.body), !created.importID.isEmpty else {
            throw ImportUploadError.badAnswer
        }
        recordRequest(kind: "import_open", body: body)
        return created.importID
    }

    /// `POST /v1/me/forget` with `{ scope: "import", import_id }`: the server wipes the space as a unit.
    public func forgetImport(id: String) async throws {
        let body = try Self.requestBody(["scope": "import", "import_id": id])
        let response = try await signedPost("v1/me/forget", body: body)
        guard (200...202).contains(response.status) else { throw ImportUploadError.rejected(status: response.status) }
        recordRequest(kind: "forget", body: body)
    }

    /// Moves staged import objects into batches under the next seqs. Objects a detector stops now are set aside and
    /// counted as blocked, never sent. Imports keep their real (old) times: no 7-day drop, the server files them under
    /// the import day (ADR 0020). Returns the ids taken out of the outbox. Synchronous: no send can interleave.
    private func batchStagedImports(_ state: inout UploadState, _ report: inout FlushReport, now: Date) throws -> Set<String> {
        guard let importOutbox, let staged = try? importOutbox.staged(), !staged.isEmpty else { return [] }
        var clean: [Observation] = []
        for o in staged {
            if ImportOutbox.isImportObject(o), (try? egress.inspect(o)) != nil { clean.append(o) } else {
                state.counters.blocked += 1
                report.blocked += 1
            }
        }
        var index = 0
        while index < clean.count {
            var n = min(config.maxObjects, clean.count - index)
            var body = try envelope(Array(clean[index..<index + n]), seq: state.nextSeq, now: now)
            while body.count > config.maxBytes, n > 1 {
                n = max(1, n * 2 / 3)
                body = try envelope(Array(clean[index..<index + n]), seq: state.nextSeq, now: now)
            }
            state.pending.append(PendingBatch(seq: state.nextSeq, body: body, lastId: clean[index + n - 1].id, objectCount: n, kind: "observation_batch"))
            state.nextSeq += 1
            index += n
        }
        return Set(staged.map(\.id))
    }

    private static func requestBody(_ fields: [String: String]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(fields)
    }

    /// One signed POST to the one host; a 401 refreshes the token once.
    private func signedPost(_ path: String, body: Data) async throws -> HTTPResponse {
        var refreshed = false
        while true {
            let token = try await tokens.token(forceRefresh: refreshed)
            let signature = Base64URL.encode(try signer.sign(body))
            let request = HTTPRequest(
                url: config.apiBase.appendingPathComponent(path), method: "POST",
                headers: [
                    "Authorization": "Bearer \(token)", "Content-Type": "application/json",
                    "Offload-Signature": "keyid=\(config.deviceID), sig=\(signature)",
                ], body: body)
            let response = try await transport.send(request)
            if response.status == 401 && !refreshed {
                refreshed = true
                continue
            }
            return response
        }
    }

    /// One sealed ledger line with the exact bytes of a request that left.
    private func recordRequest(kind: String, body: Data) {
        let entry = EgressRecord(
            time: Timestamp.format(time.now), destination: egress.host, kind: kind, objectCount: 0, bytes: body.count,
            detectors: [:], pseudonyms: [:], body: body)
        try? ledger.append(entry)
    }
}
