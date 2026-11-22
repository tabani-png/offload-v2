// Paths under the store home (`~/Library/Application Support/Offload` by default).
import Foundation

public enum KeyDomain: String, CaseIterable, Sendable {
    case days
    case egress
}

public struct StoreLayout: Sendable {
    public let home: URL

    public init(home: URL) { self.home = home }

    public static func defaultHome() -> URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Offload", isDirectory: true)
    }

    public var daysDir: URL { home.appendingPathComponent("days", isDirectory: true) }
    public var egressDir: URL { home.appendingPathComponent("egress", isDirectory: true) }
    public var keysDir: URL { home.appendingPathComponent("keys", isDirectory: true) }
    public var purgeLog: URL { home.appendingPathComponent("purge-log.jsonl") }
    public var revealFile: URL { home.appendingPathComponent("reveal.enc") }
    public var uploadStateFile: URL { home.appendingPathComponent("upload-state.enc") }
    /// The member's own "Never watch" rows, a JSON array of `{kind, value}`.
    public var exclusionsFile: URL { home.appendingPathComponent("exclusions.json") }

    public func dayFile(_ day: String) -> URL { daysDir.appendingPathComponent("\(day).jsonl.enc") }
    public func egressFile(_ day: String) -> URL { egressDir.appendingPathComponent("\(day).jsonl.enc") }
    public func keyFile(domain: KeyDomain, day: String) -> URL { keysDir.appendingPathComponent("\(domain.rawValue)-\(day).key") }

    public func directory(for domain: KeyDomain) -> URL { domain == .days ? daysDir : egressDir }
    public func file(for domain: KeyDomain, day: String) -> URL { domain == .days ? dayFile(day) : egressFile(day) }

    /// Creates home and its folders with mode 0700.
    public func ensureDirectories() throws {
        for dir in [home, daysDir, egressDir, keysDir] {
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            } catch {
                throw StoreError.io("create \(dir.lastPathComponent)")
            }
        }
    }
}

/// One lock for every file operation of the store in this process: the observer appends while the uploader reads.
enum FileGate {
    static let lock = NSRecursiveLock()
}
