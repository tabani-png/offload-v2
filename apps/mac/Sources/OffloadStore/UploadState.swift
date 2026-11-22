// What the uploader must remember across restarts: the next `seq`, every pending batch as its exact bytes (persisted
// BEFORE it is sent, so a restart resends identical bytes and seq), how far the day files have been batched, and the
// counters the app shows. Sealed with a key derived from the Keychain master key.
import Foundation
import OffloadContracts

public struct PendingBatch: Codable, Equatable, Sendable {
    public var seq: Int
    /// The exact JCS bytes of the envelope.
    public var body: Data
    /// The last object id in the batch.
    public var lastId: String
    public var objectCount: Int
    public var kind: String

    public init(seq: Int, body: Data, lastId: String, objectCount: Int, kind: String) {
        self.seq = seq
        self.body = body
        self.lastId = lastId
        self.objectCount = objectCount
        self.kind = kind
    }
}

public struct UploadCounters: Codable, Equatable, Sendable {
    /// Objects older than 7 days, dropped without sending.
    public var droppedOld = 0
    /// Objects a device detector stopped (set aside, never sent).
    public var blocked = 0
    /// Batches re-made under a new seq after a seq_replay that identical bytes did not clear.
    public var rebatched = 0
    public var sentBatches = 0
    public var sentObjects = 0
    public var failures = 0
    /// Objects the server rejected, by receipt.
    public var rejected = 0

    public init() {}
}

public struct UploadState: Codable, Equatable, Sendable {
    public var nextSeq = 1
    /// Objects with an id up to and including this one are batched, dropped or set aside.
    public var batchedThrough: String?
    public var pending: [PendingBatch] = []
    public var quarantined: [String] = []
    public var counters = UploadCounters()
    /// Consecutive failed flushes (for the back-off).
    public var failureStreak = 0
    /// Unix epoch seconds before which a scheduled flush does not try again.
    public var retryAfter: Double?

    public init() {}
}

public final class UploadStateStore: @unchecked Sendable {
    private let layout: StoreLayout
    private let keys: KeyRing

    public init(layout: StoreLayout, keys: KeyRing) {
        self.layout = layout
        self.keys = keys
    }

    public func load() throws -> UploadState {
        try FileGate.lock.withLock {
            guard let plain = try SealedFile.read(layout.uploadStateFile, key: try keys.stateKey("upload-state")) else { return UploadState() }
            do { return try JSONDecoder().decode(UploadState.self, from: plain) } catch { throw StoreError.badLine(0) }
        }
    }

    public func save(_ state: UploadState) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try FileGate.lock.withLock {
            try SealedFile.write(try encoder.encode(state), to: layout.uploadStateFile, key: try keys.stateKey("upload-state"), layout: layout)
        }
    }
}
