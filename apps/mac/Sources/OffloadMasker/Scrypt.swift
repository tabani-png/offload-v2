// scrypt (RFC 7914) on CryptoKit's HMAC-SHA256: the recovery code is stretched with it before it wraps the pseudonym key
// (ADR 0028). Tested against the RFC's first vector. `c = 1` in the PBKDF2 steps, so each step is plain HMAC blocks.
import CryptoKit
import Foundation

public enum ScryptError: Error, Equatable, Sendable {
    case badParameters
}

public enum Scrypt {
    public struct Cost: Equatable, Sendable {
        public var n: Int
        public var r: Int
        public var p: Int

        public init(n: Int, r: Int, p: Int) {
            self.n = n
            self.r = r
            self.p = p
        }

        /// 32 MiB of memory: N = 2^15, r = 8, p = 1.
        public static let standard = Cost(n: 1 << 15, r: 8, p: 1)
    }

    public static func derive(password: Data, salt: Data, n: Int, r: Int, p: Int, length: Int) throws -> Data {
        guard n > 1, n & (n - 1) == 0, n <= 1 << 22, r >= 1, p >= 1, r * p < 1 << 30, length >= 1, 128 * r * n < 1 << 31 else { throw ScryptError.badParameters }
        var b = pbkdf2One(password, salt, length: p * 128 * r)
        for i in 0..<p {
            let range = (i * 128 * r)..<((i + 1) * 128 * r)
            b.replaceSubrange(range, with: roMix(Array(b[range]), n: n, r: r))
        }
        return Data(pbkdf2One(password, Data(b), length: length))
    }

    public static func derive(password: Data, salt: Data, cost: Cost, length: Int) throws -> Data {
        try derive(password: password, salt: salt, n: cost.n, r: cost.r, p: cost.p, length: length)
    }

    /// PBKDF2-HMAC-SHA256 with one iteration.
    private static func pbkdf2One(_ password: Data, _ salt: Data, length: Int) -> [UInt8] {
        let key = SymmetricKey(data: password.isEmpty ? Data() : password)
        var out = [UInt8]()
        var block: UInt32 = 1
        while out.count < length {
            var message = salt
            message.append(contentsOf: [UInt8(block >> 24), UInt8((block >> 16) & 0xFF), UInt8((block >> 8) & 0xFF), UInt8(block & 0xFF)])
            out += Array(HMAC<SHA256>.authenticationCode(for: message, using: key))
            block += 1
        }
        return Array(out.prefix(length))
    }

    private static func roMix(_ block: [UInt8], n: Int, r: Int) -> [UInt8] {
        let words = 32 * r
        var x = [UInt32](repeating: 0, count: words)
        for i in 0..<words {
            x[i] = UInt32(block[4 * i]) | UInt32(block[4 * i + 1]) << 8 | UInt32(block[4 * i + 2]) << 16 | UInt32(block[4 * i + 3]) << 24
        }
        var v = [UInt32](repeating: 0, count: n * words)
        var scratch = [UInt32](repeating: 0, count: words)
        for i in 0..<n {
            for k in 0..<words { v[i * words + k] = x[k] }
            blockMix(&x, &scratch, r: r)
        }
        for _ in 0..<n {
            let j = Int(x[(2 * r - 1) * 16]) & (n - 1)
            for k in 0..<words { x[k] ^= v[j * words + k] }
            blockMix(&x, &scratch, r: r)
        }
        var out = [UInt8](repeating: 0, count: words * 4)
        for i in 0..<words {
            out[4 * i] = UInt8(x[i] & 0xFF)
            out[4 * i + 1] = UInt8((x[i] >> 8) & 0xFF)
            out[4 * i + 2] = UInt8((x[i] >> 16) & 0xFF)
            out[4 * i + 3] = UInt8((x[i] >> 24) & 0xFF)
        }
        return out
    }

    private static func blockMix(_ b: inout [UInt32], _ y: inout [UInt32], r: Int) {
        var x = Array(b[((2 * r - 1) * 16)..<(2 * r * 16)])
        for i in 0..<(2 * r) {
            for k in 0..<16 { x[k] ^= b[i * 16 + k] }
            salsa8(&x)
            // Even blocks first, then odd ones.
            let dest = (i % 2 == 0 ? i / 2 : r + i / 2) * 16
            for k in 0..<16 { y[dest + k] = x[k] }
        }
        b = y
    }

    private static func salsa8(_ b: inout [UInt32]) {
        var x = b
        @inline(__always) func rotl(_ a: UInt32, _ n: UInt32) -> UInt32 { (a << n) | (a >> (32 - n)) }
        for _ in 0..<4 {
            x[4] ^= rotl(x[0] &+ x[12], 7); x[8] ^= rotl(x[4] &+ x[0], 9)
            x[12] ^= rotl(x[8] &+ x[4], 13); x[0] ^= rotl(x[12] &+ x[8], 18)
            x[9] ^= rotl(x[5] &+ x[1], 7); x[13] ^= rotl(x[9] &+ x[5], 9)
            x[1] ^= rotl(x[13] &+ x[9], 13); x[5] ^= rotl(x[1] &+ x[13], 18)
            x[14] ^= rotl(x[10] &+ x[6], 7); x[2] ^= rotl(x[14] &+ x[10], 9)
            x[6] ^= rotl(x[2] &+ x[14], 13); x[10] ^= rotl(x[6] &+ x[2], 18)
            x[3] ^= rotl(x[15] &+ x[11], 7); x[7] ^= rotl(x[3] &+ x[15], 9)
            x[11] ^= rotl(x[7] &+ x[3], 13); x[15] ^= rotl(x[11] &+ x[7], 18)
            x[1] ^= rotl(x[0] &+ x[3], 7); x[2] ^= rotl(x[1] &+ x[0], 9)
            x[3] ^= rotl(x[2] &+ x[1], 13); x[0] ^= rotl(x[3] &+ x[2], 18)
            x[6] ^= rotl(x[5] &+ x[4], 7); x[7] ^= rotl(x[6] &+ x[5], 9)
            x[4] ^= rotl(x[7] &+ x[6], 13); x[5] ^= rotl(x[4] &+ x[7], 18)
            x[11] ^= rotl(x[10] &+ x[9], 7); x[8] ^= rotl(x[11] &+ x[10], 9)
            x[9] ^= rotl(x[8] &+ x[11], 13); x[10] ^= rotl(x[9] &+ x[8], 18)
            x[12] ^= rotl(x[15] &+ x[14], 7); x[13] ^= rotl(x[12] &+ x[15], 9)
            x[14] ^= rotl(x[13] &+ x[12], 13); x[15] ^= rotl(x[14] &+ x[13], 18)
        }
        for i in 0..<16 { b[i] = b[i] &+ x[i] }
    }
}
