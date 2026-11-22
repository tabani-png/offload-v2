// Append-only sealed JSON lines: one base64(nonce | ciphertext | tag) per line. Used by the day files and the egress ledger.
import CryptoKit
import Foundation

enum SealedLines {
    static func append(_ json: Data, to url: URL, key: SymmetricKey, layout: StoreLayout) throws {
        try layout.ensureDirectories()
        let sealed = try StoreCrypto.seal(json, key: key)
        let line = Data((sealed.base64EncodedString() + "\n").utf8)
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            guard fm.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw StoreError.io("create \(url.lastPathComponent)")
            }
        }
        do {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
        } catch {
            throw StoreError.io("append \(url.lastPathComponent)")
        }
    }

    /// Every line, opened. A line that does not open throws with its 1-based number.
    static func read(_ url: URL, key: SymmetricKey) throws -> [Data] {
        let data: Data
        do { data = try Data(contentsOf: url) } catch { throw StoreError.io("read \(url.lastPathComponent)") }
        var out: [Data] = []
        for (n, line) in data.split(separator: UInt8(ascii: "\n")).filter({ !$0.isEmpty }).enumerated() {
            guard let sealed = Data(base64Encoded: Data(line)) else { throw StoreError.badLine(n + 1) }
            guard let plain = StoreCrypto.open(sealed, key: key) else { throw StoreError.decryptFailed(n + 1) }
            out.append(plain)
        }
        return out
    }

    static func lineCount(_ url: URL) -> Int {
        guard let data = try? Data(contentsOf: url) else { return 0 }
        return data.split(separator: UInt8(ascii: "\n")).filter { !$0.isEmpty }.count
    }
}
