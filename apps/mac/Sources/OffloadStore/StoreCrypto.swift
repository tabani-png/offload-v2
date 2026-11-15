// AES-256-GCM seals for the day files, the egress ledger and the small state files. Sealed format is
// AES.GCM.SealedBox.combined = nonce(12) | ciphertext | tag(16). Adapted from the old engine's Store/StoreCrypto.swift.
import CryptoKit
import Foundation

public enum StoreError: Error, Equatable, Sendable {
    case invalidDay(String)
    /// The day key is missing (purged) or unreadable. Payload: the file label.
    case keyMissing(String)
    /// A key file is not the wrapped shape. Payload: the file label.
    case badKey(String)
    /// Authentication failed, or the input is shorter than nonce + tag. Payload: 1-based line number (0 for a whole file).
    case decryptFailed(Int)
    /// A line is not base64 or not a valid object. Payload: 1-based line number.
    case badLine(Int)
    case io(String)
    /// The Keychain master key is absent or not 32 bytes.
    case masterKeyMissing
    /// A Keychain call failed. Payload: the OSStatus.
    case keychain(Int32)
}

public enum StoreCrypto {
    public static let nonceSize = 12
    public static let tagSize = 16
    public static let keySize = 32

    /// Seals with AES-256-GCM and returns `SealedBox.combined`. The nonce is random.
    public static func seal(_ plaintext: Data, key: SymmetricKey, authenticating aad: Data? = nil) throws -> Data {
        let box: AES.GCM.SealedBox
        if let aad { box = try AES.GCM.seal(plaintext, using: key, authenticating: aad) } else { box = try AES.GCM.seal(plaintext, using: key) }
        guard let combined = box.combined else { throw CryptoKitError.incorrectParameterSize }
        return combined
    }

    /// Opens `SealedBox.combined` bytes. Nil on any failure (the caller reports the line).
    public static func open(_ combined: Data, key: SymmetricKey, authenticating aad: Data? = nil) -> Data? {
        guard combined.count >= nonceSize + tagSize, let box = try? AES.GCM.SealedBox(combined: combined) else { return nil }
        if let aad { return try? AES.GCM.open(box, using: key, authenticating: aad) }
        return try? AES.GCM.open(box, using: key)
    }
}
