// Stable keyed pseudonyms (ADR 0028): HMAC-SHA256(tenant pseudonym key, normalised value), first 16 hex,
// shape `<kind:h_0123456789abcdef>`. The same value gives the same pseudonym under one tenant key, never under another.
import CryptoKit
import Foundation
import Security

/// The tenant pseudonym key: 32 random bytes, created at the first enrollment and kept in the Keychain of this device.
public struct PseudonymKey: Equatable, Sendable {
    public let data: Data

    public init(data: Data) { self.data = data }

    /// 32 random bytes from the system generator.
    public static func random() throws -> PseudonymKey {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw PseudonymError.noRandomness }
        return PseudonymKey(data: Data(bytes))
    }
}

public enum PseudonymError: Error, Equatable, Sendable {
    case noRandomness
}

public enum PseudonymKind: String, CaseIterable, Sendable {
    case person, email, phone, doc
}

public struct Pseudonymizer: Sendable {
    private let keyData: Data

    public init(key: PseudonymKey) { keyData = key.data }

    /// `<kind:h_…>` for a value of that kind.
    public func pseudonym(_ kind: PseudonymKind, value: String) -> String {
        let normalised = Self.normalise(kind, value)
        let mac = HMAC<SHA256>.authenticationCode(for: Data(normalised.utf8), using: SymmetricKey(data: keyData))
        let hex = mac.prefix(8).map { String(format: "%02x", $0) }.joined()
        return "<\(kind.rawValue):h_\(hex)>"
    }

    /// NFKC and trim for all; lowercase for email and doc; phone as E.164 digits; person as lowercased "first last".
    public static func normalise(_ kind: PseudonymKind, _ value: String) -> String {
        let base = value.precomposedStringWithCompatibilityMapping.trimmingCharacters(in: .whitespacesAndNewlines)
        switch kind {
        case .email, .doc:
            var s = base.lowercased()
            if kind == .doc { while s.hasSuffix("/") { s.removeLast() } }
            return s
        case .phone:
            var digits = base.filter { $0.isASCII && $0.isNumber }
            // A ten digit national number is read as North American (+1), the same number with or without the prefix.
            if digits.count == 10 { digits = "1" + digits }
            return digits
        case .person:
            return base.lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        }
    }
}
