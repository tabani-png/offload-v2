// Keys. One 32-byte master key lives in the Keychain (service = the bundle id, account `master-key`, this device only).
// Each day file and each egress ledger day has its own key, kept on disk wrapped by the master key; deleting the key
// file is what makes a purged day unreadable. Small state files (reveal map, upload queue) use keys derived from the
// master key with HKDF. Adapted from the old engine's Store/KeyVault.swift.
import CryptoKit
import Foundation
import OffloadContracts
import Security

public final class KeyRing: @unchecked Sendable {
    public static let masterAccount = "master-key"
    /// "OKW1" | AES-GCM combined (nonce 12 | wrapped key 32 | tag 16): 64 bytes.
    static let magic = Data("OKW1".utf8)
    static let wrappedSize = 4 + StoreCrypto.nonceSize + StoreCrypto.keySize + StoreCrypto.tagSize

    public let layout: StoreLayout
    private let secrets: any SecretStore
    private let lock = NSLock()
    private var master: SymmetricKey?
    private var cache: [String: SymmetricKey] = [:]

    public init(layout: StoreLayout, secrets: any SecretStore) {
        self.layout = layout
        self.secrets = secrets
    }

    /// Drops cached keys (after a purge deleted key files).
    public func forget() { lock.withLock { cache.removeAll() } }

    private func masterKey() throws -> SymmetricKey {
        if let master { return master }
        if let data = try secrets.read(account: Self.masterAccount) {
            guard data.count == StoreCrypto.keySize else { throw StoreError.masterKeyMissing }
            let key = SymmetricKey(data: data)
            master = key
            return key
        }
        let key = SymmetricKey(size: .bits256)
        try secrets.write(key.withUnsafeBytes { Data($0) }, account: Self.masterAccount)
        master = key
        return key
    }

    private static func aad(_ domain: KeyDomain, _ day: String) -> Data { Data("ai.offload.mac/\(domain.rawValue)-key/v1/\(day)".utf8) }

    /// The key of one day of one domain. With `create`, a new random key is made when none exists.
    public func dayKey(domain: KeyDomain, day: String, create: Bool) throws -> SymmetricKey {
        try lock.withLock {
            let id = "\(domain.rawValue)-\(day)"
            if let known = cache[id] { return known }
            guard DayCalendar.isDayName(day) else { throw StoreError.invalidDay(day) }
            let url = layout.keyFile(domain: domain, day: day)
            if FileManager.default.fileExists(atPath: url.path) {
                let data: Data
                do { data = try Data(contentsOf: url) } catch { throw StoreError.keyMissing(id) }
                guard data.count == Self.wrappedSize, data.prefix(4) == Self.magic else { throw StoreError.badKey(id) }
                guard let raw = StoreCrypto.open(data.dropFirst(4), key: try masterKey(), authenticating: Self.aad(domain, day)) else {
                    throw StoreError.badKey(id)
                }
                let key = SymmetricKey(data: raw)
                cache[id] = key
                return key
            }
            guard create else { throw StoreError.keyMissing(id) }
            try layout.ensureDirectories()
            let key = SymmetricKey(size: .bits256)
            let wrapped = Self.magic + (try StoreCrypto.seal(key.withUnsafeBytes { Data($0) }, key: try masterKey(), authenticating: Self.aad(domain, day)))
            guard FileManager.default.createFile(atPath: url.path, contents: wrapped, attributes: [.posixPermissions: 0o600]) else {
                throw StoreError.io("create key file for \(id)")
            }
            cache[id] = key
            return key
        }
    }

    /// A key for a single state file, derived from the master key (HKDF-SHA256, `label` as info).
    public func stateKey(_ label: String) throws -> SymmetricKey {
        try lock.withLock {
            HKDF<SHA256>.deriveKey(inputKeyMaterial: try masterKey(), info: Data("ai.offload.mac/state/\(label)".utf8), outputByteCount: 32)
        }
    }
}

/// A sealed single-file state blob (the reveal map, the upload queue): `OSB1` | combined, written atomically.
enum SealedFile {
    static let magic = Data("OSB1".utf8)

    static func read(_ url: URL, key: SymmetricKey) throws -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data: Data
        do { data = try Data(contentsOf: url) } catch { throw StoreError.io("read \(url.lastPathComponent)") }
        guard data.prefix(4) == magic, let plain = StoreCrypto.open(data.dropFirst(4), key: key) else { throw StoreError.decryptFailed(0) }
        return plain
    }

    static func write(_ plain: Data, to url: URL, key: SymmetricKey, layout: StoreLayout) throws {
        try layout.ensureDirectories()
        let sealed = magic + (try StoreCrypto.seal(plain, key: key))
        do {
            try sealed.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            throw StoreError.io("write \(url.lastPathComponent)")
        }
    }
}
