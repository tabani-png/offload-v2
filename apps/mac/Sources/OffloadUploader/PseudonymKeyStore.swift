// The tenant pseudonym key in this device's Keychain item (service = the bundle id, this device only). A second Mac
// receives it wrapped (m3-06) or through the recovery code. Since m3-14, Local-mode capture (and the recordings import)
// creates it on the first capture, before any enrollment: on the first enrolled Mac that key becomes the tenant key; on
// a Mac that later joins a tenant as a second Mac, `store(_:)` replaces it, and the buffer masked under the local key
// must not be uploaded (follow-up for enrollment/m3-06, slices/m3-14-mac-app-integration/SPEC.md, Scope changes).
import Foundation
import OffloadMasker
import OffloadStore

public final class PseudonymKeyStore: @unchecked Sendable {
    public static let account = "pseudonym-key"
    private let secrets: any SecretStore

    public init(secrets: any SecretStore) { self.secrets = secrets }

    public func load() throws -> PseudonymKey? {
        guard let data = try secrets.read(account: Self.account), data.count == 32 else { return nil }
        return PseudonymKey(data: data)
    }

    /// The stored key, or a new random one stored now.
    public func loadOrCreate() throws -> PseudonymKey {
        if let key = try load() { return key }
        let key = try PseudonymKey.random()
        try secrets.write(key.data, account: Self.account)
        return key
    }

    /// Stores a key unwrapped from the recovery code or from another device.
    public func store(_ key: PseudonymKey) throws { try secrets.write(key.data, account: Self.account) }
}
