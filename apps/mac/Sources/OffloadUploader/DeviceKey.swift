// The device key: ECDSA P-256, in the Secure Enclave when the Mac and the app's signing allow it, else a Keychain item.
// Signatures are the raw 64-byte r‖s (JOSE / IEEE P1363), never DER (API.md "Signatures").
import CryptoKit
import Foundation
import OffloadContracts
import OffloadStore

public struct P256PublicJWK: Codable, Equatable, Sendable {
    public var kty = "EC"
    public var crv = "P-256"
    public var x: String
    public var y: String

    public init(x: String, y: String) {
        self.x = x
        self.y = y
    }

    init(x963: Data) {
        // 0x04 | X (32) | Y (32)
        self.init(x: Base64URL.encode(x963.subdata(in: 1..<33)), y: Base64URL.encode(x963.subdata(in: 33..<65)))
    }
}

public protocol DeviceSigner: Sendable {
    /// The raw r‖s signature (64 bytes) over `message`.
    func sign(_ message: Data) throws -> Data
    var publicJWK: P256PublicJWK { get }
}

public final class SoftwareDeviceSigner: DeviceSigner, @unchecked Sendable {
    private let key: P256.Signing.PrivateKey

    public init(privateKey: P256.Signing.PrivateKey = P256.Signing.PrivateKey()) { key = privateKey }

    public func sign(_ message: Data) throws -> Data { try key.signature(for: message).rawRepresentation }

    public var publicJWK: P256PublicJWK { P256PublicJWK(x963: key.publicKey.x963Representation) }

    var rawRepresentation: Data { key.rawRepresentation }
}

public final class SecureEnclaveDeviceSigner: DeviceSigner, @unchecked Sendable {
    private let key: SecureEnclave.P256.Signing.PrivateKey

    init(key: SecureEnclave.P256.Signing.PrivateKey) { self.key = key }

    public func sign(_ message: Data) throws -> Data { try key.signature(for: message).rawRepresentation }

    public var publicJWK: P256PublicJWK { P256PublicJWK(x963: key.publicKey.x963Representation) }

    var dataRepresentation: Data { key.dataRepresentation }
}

public enum DeviceKey {
    static let secureEnclaveAccount = "device-key-se"
    static let softwareAccount = "device-key"

    /// The key of this Mac and where it lives (`secure_enclave` or `keychain`, as the enroll call names it).
    public static func loadOrCreate(secrets: any SecretStore, preferSecureEnclave: Bool = true) throws -> (signer: any DeviceSigner, keyStorage: String) {
        if let blob = try secrets.read(account: secureEnclaveAccount), let key = try? SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: blob) {
            return (SecureEnclaveDeviceSigner(key: key), "secure_enclave")
        }
        if let raw = try secrets.read(account: softwareAccount) {
            return (SoftwareDeviceSigner(privateKey: try P256.Signing.PrivateKey(rawRepresentation: raw)), "keychain")
        }
        if preferSecureEnclave, SecureEnclave.isAvailable, let key = try? SecureEnclave.P256.Signing.PrivateKey() {
            let signer = SecureEnclaveDeviceSigner(key: key)
            try secrets.write(signer.dataRepresentation, account: secureEnclaveAccount)
            return (signer, "secure_enclave")
        }
        let signer = SoftwareDeviceSigner()
        try secrets.write(signer.rawRepresentation, account: softwareAccount)
        return (signer, "keychain")
    }
}
