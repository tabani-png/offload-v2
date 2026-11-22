import Foundation

// JSON values and the RFC 8785 JCS bytes of the small bodies the Mac posts (API.md section 1, "Signatures"): the
// server checks body == jcs(JSON.parse(body)) and verifies the device signature over exactly these bytes.

/// Any JSON value. Used for request bodies (encoded with `JCS.encode`) and for response parts Offload keeps as they
/// came (a fix's brief, a build's definition).
public enum JSONValue: Codable, Equatable, Hashable, Sendable {
  case null
  case bool(Bool)
  case number(Double)
  case string(String)
  case array([JSONValue])
  case object([String: JSONValue])

  public init(from decoder: any Decoder) throws {
    let c = try decoder.singleValueContainer()
    if c.decodeNil() {
      self = .null
    } else if let b = try? c.decode(Bool.self) {
      self = .bool(b)
    } else if let d = try? c.decode(Double.self) {
      self = .number(d)
    } else if let s = try? c.decode(String.self) {
      self = .string(s)
    } else if let a = try? c.decode([JSONValue].self) {
      self = .array(a)
    } else {
      self = .object(try c.decode([String: JSONValue].self))
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var c = encoder.singleValueContainer()
    switch self {
    case .null: try c.encodeNil()
    case .bool(let b): try c.encode(b)
    case .number(let d): try c.encode(d)
    case .string(let s): try c.encode(s)
    case .array(let a): try c.encode(a)
    case .object(let o): try c.encode(o)
    }
  }

  /// The string when this is a string, else nil.
  public var stringValue: String? {
    if case .string(let s) = self { return s }
    return nil
  }

  /// The number when this is a number, else nil.
  public var numberValue: Double? {
    if case .number(let d) = self { return d }
    return nil
  }

  /// The member `key` when this is an object, else nil.
  public subscript(key: String) -> JSONValue? {
    if case .object(let o) = self { return o[key] }
    return nil
  }
}

/// A JSON value that has no JCS form (a NaN or infinite number).
public struct JCSEncodingError: Error, Equatable, Sendable {
  public let reason: String
  public init(reason: String) { self.reason = reason }
}

/// RFC 8785 canonical JSON for the Mac's flat request bodies: object keys sorted by their UTF-16 code units, no
/// whitespace, integral numbers without a fraction (`4.0` is `4`), strings escaped with JSON escapes only (`"`, `\`
/// and control characters; `\b \f \n \r \t` short forms, other controls `\u00xx` in lowercase hex; everything else,
/// non-ASCII included, written as is). Non-integral numbers use Swift's shortest round-trip form with the exponent
/// written as ECMAScript does (`1e-7`); the bodies the Mac signs hold only strings, integers and booleans.
public enum JCS {
  public static func encode(_ value: JSONValue) throws -> Data {
    var out = ""
    try write(value, into: &out)
    return Data(out.utf8)
  }

  /// The canonical text, for tests and logs of bodies (never of headers).
  public static func string(_ value: JSONValue) throws -> String {
    var out = ""
    try write(value, into: &out)
    return out
  }

  static func write(_ value: JSONValue, into out: inout String) throws {
    switch value {
    case .null:
      out += "null"
    case .bool(let b):
      out += b ? "true" : "false"
    case .number(let d):
      out += try number(d)
    case .string(let s):
      out += quoted(s)
    case .array(let items):
      out += "["
      var first = true
      for item in items {
        if !first { out += "," }
        first = false
        try write(item, into: &out)
      }
      out += "]"
    case .object(let members):
      out += "{"
      let keys = members.keys.sorted { a, b in a.utf16.lexicographicallyPrecedes(b.utf16) }
      var first = true
      for key in keys {
        guard let member = members[key] else { continue }
        if !first { out += "," }
        first = false
        out += quoted(key)
        out += ":"
        try write(member, into: &out)
      }
      out += "}"
    }
  }

  /// ECMAScript number text for the values the Mac sends.
  public static func number(_ d: Double) throws -> String {
    guard d.isFinite else { throw JCSEncodingError(reason: "a number must be finite") }
    if d == 0 { return "0" }  // -0 is written as 0
    if d == d.rounded(.towardZero), abs(d) < 9.0e15 {
      return String(Int64(d))
    }
    let text = "\(d)"
    guard let e = text.firstIndex(where: { $0 == "e" || $0 == "E" }) else { return text }
    let mantissa = String(text[text.startIndex..<e])
    let exponentText = String(text[text.index(after: e)...])
    guard let exponent = Int(exponentText) else { return text }
    return mantissa + "e" + (exponent < 0 ? "-" : "+") + String(abs(exponent))
  }

  /// A JSON string literal with RFC 8785 escaping.
  public static func quoted(_ s: String) -> String {
    var out = "\""
    for scalar in s.unicodeScalars {
      switch scalar.value {
      case 0x22: out += "\\\""
      case 0x5C: out += "\\\\"
      case 0x08: out += "\\b"
      case 0x0C: out += "\\f"
      case 0x0A: out += "\\n"
      case 0x0D: out += "\\r"
      case 0x09: out += "\\t"
      case 0x00..<0x20:
        let hex = String(scalar.value, radix: 16, uppercase: false)
        out += "\\u" + String(repeating: "0", count: 4 - hex.count) + hex
      default:
        out.unicodeScalars.append(scalar)
      }
    }
    out += "\""
    return out
  }
}
