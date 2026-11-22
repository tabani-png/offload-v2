// RFC 8785 JSON Canonicalization Scheme. The Swift twin of packages/contracts/src/jcs.ts: same bytes for the same value
// (tested against the shared vectors in packages/contracts/tests/fixtures/jcs). Strict on purpose: a value JSON cannot
// represent (NaN, infinity, a lone surrogate, a duplicate key) throws, so signed bytes are never ambiguous.
import Foundation

public enum JSONValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
}

public struct JCSError: Error, Equatable, CustomStringConvertible, Sendable {
    public let description: String
    init(_ description: String) { self.description = description }
}

public enum JCS {
    /// The canonical form of one JSON text.
    public static func canonicalize(json: Data) throws -> Data {
        try canonicalize(JSONParser.parse(json))
    }

    public static func canonicalize(_ value: JSONValue) throws -> Data {
        var out = [UInt8]()
        try write(value, into: &out)
        return Data(out)
    }

    /// The canonical form of anything Codable (what the uploader signs and sends).
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        return try canonicalize(json: encoder.encode(value))
    }

    private static func write(_ value: JSONValue, into out: inout [UInt8]) throws {
        switch value {
        case .null: out += Array("null".utf8)
        case .bool(let b): out += Array((b ? "true" : "false").utf8)
        case .number(let d): out += Array(try numberText(d).utf8)
        case .string(let s): writeString(s, into: &out)
        case .array(let items):
            out.append(UInt8(ascii: "["))
            for (i, item) in items.enumerated() {
                if i > 0 { out.append(UInt8(ascii: ",")) }
                try write(item, into: &out)
            }
            out.append(UInt8(ascii: "]"))
        case .object(let members):
            // Property names sort by UTF-16 code units (RFC 8785 section 3.2.3).
            let keys = members.keys.sorted { Array($0.utf16).lexicographicallyPrecedes(Array($1.utf16)) }
            out.append(UInt8(ascii: "{"))
            for (i, key) in keys.enumerated() {
                if i > 0 { out.append(UInt8(ascii: ",")) }
                writeString(key, into: &out)
                out.append(UInt8(ascii: ":"))
                try write(members[key]!, into: &out)
            }
            out.append(UInt8(ascii: "}"))
        }
    }

    private static func writeString(_ s: String, into out: inout [UInt8]) {
        out.append(UInt8(ascii: "\""))
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += Array("\\\"".utf8)
            case "\\": out += Array("\\\\".utf8)
            case "\u{08}": out += Array("\\b".utf8)
            case "\u{0C}": out += Array("\\f".utf8)
            case "\n": out += Array("\\n".utf8)
            case "\r": out += Array("\\r".utf8)
            case "\t": out += Array("\\t".utf8)
            default:
                if scalar.value < 0x20 {
                    out += Array(String(format: "\\u%04x", scalar.value).utf8)
                } else {
                    out += Array(String(scalar).utf8)
                }
            }
        }
        out.append(UInt8(ascii: "\""))
    }

    /// ECMAScript Number::toString (RFC 8785 section 3.2.2.3).
    static func numberText(_ v: Double) throws -> String {
        guard v.isFinite else { throw JCSError("non-finite number") }
        if v == 0 { return "0" }
        if v < 0 { return "-" + (try numberText(-v)) }
        // Swift's description is the shortest round-trip digit string; re-lay it out the ECMAScript way.
        let text = "\(v)"
        var mantissa = text
        var exponent = 0
        if let e = text.firstIndex(where: { $0 == "e" || $0 == "E" }) {
            mantissa = String(text[..<e])
            exponent = Int(text[text.index(after: e)...].replacingOccurrences(of: "+", with: "")) ?? 0
        }
        let parts = mantissa.split(separator: ".", omittingEmptySubsequences: false)
        let intPart = String(parts[0])
        let fracPart = parts.count > 1 ? String(parts[1]) : ""
        var digits = Array(intPart + fracPart)
        var n = intPart.count + exponent
        while digits.first == "0" { digits.removeFirst(); n -= 1 }
        while digits.last == "0" { digits.removeLast() }
        let k = digits.count
        let s = String(digits)
        if k <= n && n <= 21 { return s + String(repeating: "0", count: n - k) }
        if 0 < n && n <= 21 { return String(digits[..<n]) + "." + String(digits[n...]) }
        if -6 < n && n <= 0 { return "0." + String(repeating: "0", count: -n) + s }
        let e = n - 1
        let sign = e < 0 ? "-" : "+"
        let head = String(digits[0])
        let tail = k > 1 ? "." + String(digits[1...]) : ""
        return "\(head)\(tail)e\(sign)\(abs(e))"
    }
}

/// A small strict JSON parser: no comments, no trailing commas, no duplicate keys, no lone surrogates.
public enum JSONParser {
    public static func parse(_ data: Data) throws -> JSONValue {
        var p = Cursor(bytes: [UInt8](data))
        p.skipSpace()
        let value = try p.value(depth: 0)
        p.skipSpace()
        guard p.index == p.bytes.count else { throw JCSError("trailing characters") }
        return value
    }

    private struct Cursor {
        let bytes: [UInt8]
        var index = 0

        init(bytes: [UInt8]) { self.bytes = bytes }

        mutating func skipSpace() {
            while index < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) { index += 1 }
        }

        mutating func value(depth: Int) throws -> JSONValue {
            guard depth < 512 else { throw JCSError("nesting too deep") }
            guard index < bytes.count else { throw JCSError("unexpected end") }
            switch bytes[index] {
            case UInt8(ascii: "{"): return try object(depth: depth)
            case UInt8(ascii: "["): return try array(depth: depth)
            case UInt8(ascii: "\""): return .string(try string())
            case UInt8(ascii: "t"): try literal("true"); return .bool(true)
            case UInt8(ascii: "f"): try literal("false"); return .bool(false)
            case UInt8(ascii: "n"): try literal("null"); return .null
            default: return try number()
            }
        }

        mutating func literal(_ word: String) throws {
            let w = Array(word.utf8)
            guard index + w.count <= bytes.count, Array(bytes[index..<index + w.count]) == w else { throw JCSError("bad literal") }
            index += w.count
        }

        mutating func number() throws -> JSONValue {
            let start = index
            while index < bytes.count, "+-.eE0123456789".utf8.contains(bytes[index]) { index += 1 }
            let text = String(decoding: bytes[start..<index], as: UTF8.self)
            guard !text.isEmpty, let d = Double(text), !text.hasPrefix("+"), !text.hasPrefix(".") else { throw JCSError("bad number") }
            return .number(d)
        }

        mutating func array(depth: Int) throws -> JSONValue {
            index += 1
            var items: [JSONValue] = []
            skipSpace()
            if index < bytes.count, bytes[index] == UInt8(ascii: "]") { index += 1; return .array(items) }
            while true {
                skipSpace()
                items.append(try value(depth: depth + 1))
                skipSpace()
                guard index < bytes.count else { throw JCSError("unterminated array") }
                if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
                if bytes[index] == UInt8(ascii: "]") { index += 1; return .array(items) }
                throw JCSError("bad array")
            }
        }

        mutating func object(depth: Int) throws -> JSONValue {
            index += 1
            var members: [String: JSONValue] = [:]
            skipSpace()
            if index < bytes.count, bytes[index] == UInt8(ascii: "}") { index += 1; return .object(members) }
            while true {
                skipSpace()
                guard index < bytes.count, bytes[index] == UInt8(ascii: "\"") else { throw JCSError("bad key") }
                let key = try string()
                skipSpace()
                guard index < bytes.count, bytes[index] == UInt8(ascii: ":") else { throw JCSError("missing colon") }
                index += 1
                skipSpace()
                guard members[key] == nil else { throw JCSError("duplicate key") }
                members[key] = try value(depth: depth + 1)
                skipSpace()
                guard index < bytes.count else { throw JCSError("unterminated object") }
                if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
                if bytes[index] == UInt8(ascii: "}") { index += 1; return .object(members) }
                throw JCSError("bad object")
            }
        }

        mutating func hex4() throws -> UInt32 {
            guard index + 4 <= bytes.count else { throw JCSError("bad escape") }
            let text = String(decoding: bytes[index..<index + 4], as: UTF8.self)
            guard let v = UInt32(text, radix: 16) else { throw JCSError("bad escape") }
            index += 4
            return v
        }

        mutating func string() throws -> String {
            index += 1
            var out = [UInt8]()
            while true {
                guard index < bytes.count else { throw JCSError("unterminated string") }
                let b = bytes[index]
                index += 1
                switch b {
                case UInt8(ascii: "\""):
                    guard let s = String(bytes: out, encoding: .utf8) else { throw JCSError("invalid UTF-8") }
                    return s
                case UInt8(ascii: "\\"):
                    guard index < bytes.count else { throw JCSError("bad escape") }
                    let e = bytes[index]
                    index += 1
                    switch e {
                    case UInt8(ascii: "\""): out.append(0x22)
                    case UInt8(ascii: "\\"): out.append(0x5C)
                    case UInt8(ascii: "/"): out.append(0x2F)
                    case UInt8(ascii: "b"): out.append(0x08)
                    case UInt8(ascii: "f"): out.append(0x0C)
                    case UInt8(ascii: "n"): out.append(0x0A)
                    case UInt8(ascii: "r"): out.append(0x0D)
                    case UInt8(ascii: "t"): out.append(0x09)
                    case UInt8(ascii: "u"):
                        var code = try hex4()
                        if (0xD800...0xDBFF).contains(code) {
                            guard index + 6 <= bytes.count, bytes[index] == UInt8(ascii: "\\"), bytes[index + 1] == UInt8(ascii: "u") else {
                                throw JCSError("lone surrogate")
                            }
                            index += 2
                            let low = try hex4()
                            guard (0xDC00...0xDFFF).contains(low) else { throw JCSError("lone surrogate") }
                            code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
                        } else if (0xDC00...0xDFFF).contains(code) {
                            throw JCSError("lone surrogate")
                        }
                        guard let scalar = Unicode.Scalar(code) else { throw JCSError("bad scalar") }
                        out += Array(String(scalar).utf8)
                    default: throw JCSError("bad escape")
                    }
                default:
                    guard b >= 0x20 else { throw JCSError("control character in string") }
                    out.append(b)
                }
            }
        }
    }
}
