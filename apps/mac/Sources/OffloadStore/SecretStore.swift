// Small secrets by account name. The live one is the Keychain; tests use MemorySecretStore.
import Foundation
import Security

public protocol SecretStore: AnyObject, Sendable {
    /// Nil when there is no item for `account`.
    func read(account: String) throws -> Data?
    /// Creates or replaces the item.
    func write(_ data: Data, account: String) throws
    /// No error when the item is absent.
    func delete(account: String) throws
}

public final class MemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: Data] = [:]

    public init() {}

    public func read(account: String) throws -> Data? { lock.withLock { items[account] } }
    public func write(_ data: Data, account: String) throws { lock.withLock { items[account] = data } }
    public func delete(account: String) throws { lock.withLock { items[account] = nil } }
}

/// Generic-password items in the Keychain, readable after the first sign-in following a restart and never synced or
/// migrated to another device. The service is the app's bundle id: `ai.offload.mac` for release builds and
/// `ai.offload.mac.dev` for dev builds, which never share keys.
public final class KeychainSecretStore: SecretStore, @unchecked Sendable {
    public static let releaseService = "ai.offload.mac"
    public static let devService = "ai.offload.mac.dev"

    public let service: String

    public init(service: String) { self.service = service }

    /// The service for a bundle id. Only the release id gets the release service; any other (dev builds, the test
    /// runner, a command line tool) gets the dev one, so a stray process can never read or write release keys.
    public static func service(forBundleID bundleID: String?) -> String {
        bundleID == releaseService ? releaseService : devService
    }

    public convenience init(bundleID: String? = Bundle.main.bundleIdentifier) {
        self.init(service: Self.service(forBundleID: bundleID))
    }

    private func base(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    public func read(account: String) throws -> Data? {
        var query = base(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw StoreError.keychain(status) }
        guard let data = item as? Data else { throw StoreError.keychain(errSecDecode) }
        return data
    }

    public func write(_ data: Data, account: String) throws {
        let update = SecItemUpdate(base(account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw StoreError.keychain(update) }
        var add = base(account)
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        add[kSecAttrLabel as String] = "Offload (\(account))"
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw StoreError.keychain(status) }
    }

    public func delete(account: String) throws {
        let status = SecItemDelete(base(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw StoreError.keychain(status) }
    }
}
