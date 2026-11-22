// Recordings-import objects staged on this Mac before the uploader batches them (slice m3-14-mac-app-integration).
// The import's sink hands objects here synchronously, so when `stage` returns they are durable and the importer may
// record the file as done; when it throws, nothing was kept and the importer reads the file again next time. One
// sealed state file next to the upload queue (`import-outbox.enc`, AES-GCM under a key derived from the master key),
// written atomically. The uploader drains it at the start of a flush, in the same step that saves the queue.
import Foundation
import OffloadContracts
import OffloadStore

public final class ImportOutbox: @unchecked Sendable {
    static let magic = Data("OIB1".utf8)
    /// Process-wide: the sink and the uploader may hold different instances over the same file.
    private static let lock = NSLock()

    public let layout: StoreLayout
    private let keys: KeyRing

    public init(layout: StoreLayout, keys: KeyRing) {
        self.layout = layout
        self.keys = keys
    }

    public var file: URL { layout.home.appendingPathComponent("import-outbox.enc") }

    /// Every object must be `source = "import"` with an `import_id` and pass the device detectors; otherwise nothing is
    /// stored and this throws (fail closed).
    public func stage(_ objects: [Observation], checkedBy egress: EgressGuard) throws {
        guard !objects.isEmpty else { return }
        for o in objects where !Self.isImportObject(o) { throw ImportUploadError.notAnImportObject }
        for o in objects { try egress.inspect(o) }
        try Self.lock.withLock {
            var all = try readLocked()
            all.append(contentsOf: objects)
            try writeLocked(all)
        }
    }

    /// Staged objects, oldest hand-off first.
    public func staged() throws -> [Observation] { try Self.lock.withLock { try readLocked() } }

    public func remove(ids: Set<String>) throws {
        guard !ids.isEmpty else { return }
        try Self.lock.withLock {
            let kept = try readLocked().filter { !ids.contains($0.id) }
            try writeLocked(kept)
        }
    }

    static func isImportObject(_ o: Observation) -> Bool {
        let tags: (ObservationSource?, String?)
        switch o {
        case .focus(let v): tags = (v.source, v.importId)
        case .idleStart(let v): tags = (v.source, v.importId)
        case .idleEnd(let v): tags = (v.source, v.importId)
        case .inputCounts(let v): tags = (v.source, v.importId)
        case .textSnapshot(let v): tags = (v.source, v.importId)
        case .pause(let v): tags = (v.source, v.importId)
        case .resume(let v): tags = (v.source, v.importId)
        case .permissionChange(let v): tags = (v.source, v.importId)
        }
        return tags.0 == .import && !(tags.1 ?? "").isEmpty
    }

    private func readLocked() throws -> [Observation] {
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        let data: Data
        do { data = try Data(contentsOf: file) } catch { throw StoreError.io("read import outbox") }
        guard data.prefix(4) == Self.magic,
              let plain = StoreCrypto.open(Data(data.dropFirst(4)), key: try keys.stateKey("import-outbox")) else {
            throw StoreError.decryptFailed(0)
        }
        do { return try JSONDecoder().decode([Observation].self, from: plain) } catch { throw StoreError.badLine(0) }
    }

    private func writeLocked(_ objects: [Observation]) throws {
        try layout.ensureDirectories()
        let sealed = Self.magic + (try StoreCrypto.seal(try JSONEncoder().encode(objects), key: try keys.stateKey("import-outbox")))
        do {
            try sealed.write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        } catch {
            throw StoreError.io("write import outbox")
        }
    }
}
