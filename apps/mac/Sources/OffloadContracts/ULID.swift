// ULID (Crockford base32, 48-bit ms time + 80-bit randomness). Monotonic within one generator, so ids sort the way
// observations were written. Adapted from the old engine's Model/ULID.swift.
import Foundation
import Security

public final class ULIDGenerator: @unchecked Sendable {
    private static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
    private let lock = NSLock()
    private let random: @Sendable () -> [UInt8]
    private var lastMillis: Int64 = -1
    private var lastRandom: [UInt8] = []

    /// `random` must return 10 bytes. Default: SecRandomCopyBytes.
    public init(random: (@Sendable () -> [UInt8])? = nil) {
        self.random = random ?? ULIDGenerator.secureRandom
    }

    public func next(millis: Int64) -> String {
        lock.withLock {
            var bytes: [UInt8]
            if millis <= lastMillis, !lastRandom.isEmpty {
                // Same millisecond (or a clock step back): keep the time part rising so ids stay ordered.
                bytes = lastRandom
                Self.increment(&bytes)
                let at = max(millis, lastMillis)
                lastRandom = bytes
                return Self.encode(millis: at, random: bytes)
            }
            bytes = random()
            if bytes.count != 10 { bytes = Array((bytes + [UInt8](repeating: 0, count: 10)).prefix(10)) }
            lastMillis = millis
            lastRandom = bytes
            return Self.encode(millis: millis, random: bytes)
        }
    }

    /// The millisecond timestamp inside a ULID, or nil when the text is not one.
    public static func millis(of ulid: String) -> Int64? {
        let chars = Array(ulid)
        guard chars.count == 26 else { return nil }
        var t: Int64 = 0
        for c in chars[0..<10] {
            guard let i = alphabet.firstIndex(of: c) else { return nil }
            t = t << 5 | Int64(i)
        }
        return t
    }

    static func encode(millis: Int64, random: [UInt8]) -> String {
        var out = [Character]()
        out.reserveCapacity(26)
        let t = UInt64(max(0, millis)) & 0xFFFF_FFFF_FFFF
        for i in stride(from: 9, through: 0, by: -1) { out.append(alphabet[Int((t >> UInt64(i * 5)) & 0x1F)]) }
        var acc: UInt32 = 0
        var bits = 0
        for byte in random {
            acc = (acc << 8) | UInt32(byte)
            bits += 8
            while bits >= 5 {
                bits -= 5
                out.append(alphabet[Int((acc >> UInt32(bits)) & 0x1F)])
            }
            acc &= (1 << UInt32(bits)) - 1
        }
        return String(out)
    }

    private static func increment(_ bytes: inout [UInt8]) {
        for i in stride(from: bytes.count - 1, through: 0, by: -1) {
            if bytes[i] == 0xFF { bytes[i] = 0 } else { bytes[i] += 1; return }
        }
    }

    private static func secureRandom() -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 10)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            for i in bytes.indices { bytes[i] = UInt8.random(in: 0...255) }
        }
        return bytes
    }
}
