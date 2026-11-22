import CryptoKit
import Foundation

// Every number a screen shows is a Figure (ADR 0003): the value, its unit, how it was counted and what it was counted
// from. The shape is API.md section 1's, so a local figure and a cloud figure read the same on every screen. Local
// figures use evidence kind `observation` with the ids of the observations kept on this Mac.

public struct EvidenceRef: Codable, Equatable, Hashable, Sendable {
  public var kind: String
  public var id: String

  public init(kind: String, id: String) {
    self.kind = kind
    self.id = id
  }

  /// One observation kept on this Mac.
  public static func observation(_ id: String) -> EvidenceRef { EvidenceRef(kind: "observation", id: id) }
}

public struct Figure: Codable, Equatable, Hashable, Sendable {
  /// `fig_` + first 16 hex of SHA-256 over the JCS of the figure without `id`.
  public var id: String
  public var value: Double
  /// The brain's units (`minutes`, `hours`, `count`, `per_hour`, `minutes_per_week`, …), plus `seconds` for local
  /// figures, which never leave the Mac.
  public var unit: String
  public var arithmetic: String
  public var evidence: [EvidenceRef]
  /// Always present on the wire; null while the evidence exists.
  public var sourcePurgedAt: String?

  public init(id: String, value: Double, unit: String, arithmetic: String, evidence: [EvidenceRef], sourcePurgedAt: String?) {
    self.id = id
    self.value = value
    self.unit = unit
    self.arithmetic = arithmetic
    self.evidence = evidence
    self.sourcePurgedAt = sourcePurgedAt
  }

  /// A figure counted on this Mac, with its id computed as API.md says.
  public static func local(_ value: Double, unit: String, arithmetic: String, evidence: [EvidenceRef]) -> Figure {
    Figure(id: id(value: value, unit: unit, arithmetic: arithmetic, evidence: evidence, sourcePurgedAt: nil), value: value,
           unit: unit, arithmetic: arithmetic, evidence: evidence, sourcePurgedAt: nil)
  }

  public static func id(value: Double, unit: String, arithmetic: String, evidence: [EvidenceRef], sourcePurgedAt: String?) -> String {
    let body = FigureCanon.object([
      ("arithmetic", FigureCanon.string(arithmetic)),
      ("evidence", "[" + evidence.map { FigureCanon.object([("id", FigureCanon.string($0.id)), ("kind", FigureCanon.string($0.kind))]) }
        .joined(separator: ",") + "]"),
      ("source_purged_at", sourcePurgedAt.map(FigureCanon.string) ?? "null"),
      ("unit", FigureCanon.string(unit)),
      ("value", FigureCanon.number(value)),
    ])
    let digest = SHA256.hash(data: Data(body.utf8))
    return "fig_" + digest.map { String(format: "%02x", $0) }.joined().prefix(16)
  }

  enum CodingKeys: String, CodingKey {
    case id, value, unit, arithmetic, evidence
    case sourcePurgedAt = "source_purged_at"
  }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.decode(String.self, forKey: .id)
    value = try c.decode(Double.self, forKey: .value)
    unit = try c.decode(String.self, forKey: .unit)
    arithmetic = try c.decode(String.self, forKey: .arithmetic)
    evidence = try c.decodeIfPresent([EvidenceRef].self, forKey: .evidence) ?? []
    sourcePurgedAt = try c.decodeIfPresent(String.self, forKey: .sourcePurgedAt)
  }

  public func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(id, forKey: .id)
    try c.encode(value, forKey: .value)
    try c.encode(unit, forKey: .unit)
    try c.encode(arithmetic, forKey: .arithmetic)
    try c.encode(evidence, forKey: .evidence)
    // Always present, null allowed (API.md).
    if let sourcePurgedAt { try c.encode(sourcePurgedAt, forKey: .sourcePurgedAt) } else { try c.encodeNil(forKey: .sourcePurgedAt) }
  }

  /// A zero with nothing behind it: "nothing counted". Never an invented number.
  public static func nothing(unit: String) -> Figure {
    local(0, unit: unit, arithmetic: AnalysisCopy.nothingCounted, evidence: [])
  }
}

/// The few RFC 8785 rules a figure body needs: sorted keys (the caller passes them sorted), no whitespace, strings
/// with JSON escapes only, numbers as ECMAScript prints them for the values figures hold.
enum FigureCanon {
  static func object(_ pairs: [(String, String)]) -> String {
    "{" + pairs.map { string($0.0) + ":" + $0.1 }.joined(separator: ",") + "}"
  }

  static func string(_ s: String) -> String {
    var out = "\""
    for scalar in s.unicodeScalars {
      switch scalar {
      case "\"": out += "\\\""
      case "\\": out += "\\\\"
      case "\u{08}": out += "\\b"
      case "\u{0C}": out += "\\f"
      case "\n": out += "\\n"
      case "\r": out += "\\r"
      case "\t": out += "\\t"
      default:
        if scalar.value < 0x20 {
          out += String(format: "\\u%04x", scalar.value)
        } else {
          out.unicodeScalars.append(scalar)
        }
      }
    }
    return out + "\""
  }

  /// Whole numbers without a fraction ("145"), others in the shortest form that reads back ("1.5", "0.75").
  static func number(_ v: Double) -> String {
    guard v.isFinite else { return "0" }
    if v == v.rounded(), abs(v) < 1e15 { return String(Int64(v)) }
    return "\(v)"
  }
}
