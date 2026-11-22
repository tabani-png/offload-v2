// The pseudonym key under the recovery code (ADR 0028). The recovery code is shown once at the first enrollment; the key
// is wrapped by a key derived from it with scrypt, and that wrapped copy is what the server stores
// (`PUT /v1/devices/{id}/pseudonym-key-wrap`, ciphertext only). The key itself never leaves this Mac in the clear.
import CryptoKit
import Foundation
import OffloadContracts
import Security

public enum KeyWrapError: Error, Equatable, Sendable {
    case malformed
    /// The recovery code does not open this wrap.
    case wrongRecoveryCode
    case noRandomness
}

public enum RecoveryCode {
    private static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

    /// 160 random bits as 32 Crockford base32 characters in 8 groups: `ABCD-EFGH-...`.
    public static func generate() -> String {
        var bytes = [UInt8](repeating: 0, count: 20)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            for i in bytes.indices { bytes[i] = UInt8.random(in: 0...255) }
        }
        var chars: [Character] = []
        var acc: UInt32 = 0
        var bits = 0
        for byte in bytes {
            acc = (acc << 8) | UInt32(byte)
            bits += 8
            while bits >= 5 {
                bits -= 5
                chars.append(alphabet[Int((acc >> UInt32(bits)) & 0x1F)])
            }
            acc &= (1 << UInt32(bits)) - 1
        }
        return stride(from: 0, to: chars.count, by: 4).map { String(chars[$0..<min($0 + 4, chars.count)]) }.joined(separator: "-")
    }

    /// What was typed, read the way Crockford base32 allows: case, dashes and spaces ignored, O as 0, I and L as 1.
    public static func normalise(_ typed: String) -> String {
        String(typed.uppercased().filter { $0 != "-" && !$0.isWhitespace }.map { c -> Character in
            switch c {
            case "O": return "0"
            case "I", "L": return "1"
            default: return c
            }
        })
    }
}

public enum KeyWrap {
    static let magic = Data("OPK1".utf8)
    static let aad = Data("ai.offload/pseudonym-key-wrap/v1".utf8)

    /// `OPK1` | N, r, p (UInt32 big endian) | salt (16) | AES-256-GCM combined of the key.
    public static func wrap(_ key: PseudonymKey, recoveryCode: String, cost: Scrypt.Cost = .standard) throws -> Data {
        var salt = [UInt8](repeating: 0, count: 16)
        guard SecRandomCopyBytes(kSecRandomDefault, salt.count, &salt) == errSecSuccess else { throw KeyWrapError.noRandomness }
        let derived = try Scrypt.derive(password: Data(RecoveryCode.normalise(recoveryCode).utf8), salt: Data(salt), cost: cost, length: 32)
        let box = try AES.GCM.seal(key.data, using: SymmetricKey(data: derived), authenticating: aad)
        guard let combined = box.combined else { throw KeyWrapError.malformed }
        var out = magic
        for v in [cost.n, cost.r, cost.p] { out.append(contentsOf: be32(UInt32(v))) }
        return out + Data(salt) + combined
    }

    public static func unwrap(_ blob: Data, recoveryCode: String) throws -> PseudonymKey {
        let header = 4 + 12 + 16
        guard blob.count > header, blob.prefix(4) == magic else { throw KeyWrapError.malformed }
        let b = [UInt8](blob)
        func word(_ at: Int) -> Int { Int(b[at]) << 24 | Int(b[at + 1]) << 16 | Int(b[at + 2]) << 8 | Int(b[at + 3]) }
        let cost = Scrypt.Cost(n: word(4), r: word(8), p: word(12))
        // A wrap from the server is not trusted to pick an absurd cost.
        guard cost.n <= 1 << 20, cost.r <= 16, cost.p <= 4 else { throw KeyWrapError.malformed }
        let salt = Data(b[16..<32])
        let derived = try Scrypt.derive(password: Data(RecoveryCode.normalise(recoveryCode).utf8), salt: salt, cost: cost, length: 32)
        guard let box = try? AES.GCM.SealedBox(combined: Data(b[32...])),
              let plain = try? AES.GCM.open(box, using: SymmetricKey(data: derived), authenticating: aad), plain.count == 32 else {
            throw KeyWrapError.wrongRecoveryCode
        }
        return PseudonymKey(data: plain)
    }

    /// The body of `PUT /v1/devices/{id}/pseudonym-key-wrap` from the first device: the wrap is both this device's copy and
    /// the tenant's recovery copy.
    public static func putBody(for wrapped: Data) throws -> Data {
        let text = Base64URL.encode(wrapped)
        let object: [String: Any] = ["wrapped_key": text, "wrapped_by_device_id": NSNull(), "method": "recovery_code", "recovery_wrap": text]
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private static func be32(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)] }
}
