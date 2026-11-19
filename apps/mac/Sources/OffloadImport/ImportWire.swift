import CryptoKit
import Foundation

// The import's wire shapes, matching the m1-02 contracts (packages/contracts/src/ingest.ts, schemas
// observation.schema.json) and API.md (`POST /v1/imports`, `POST /v1/me/forget` scope `import`). OffloadContracts
// gets generated types with m3-02; until then these are written by hand and tested against the contract's keys.

/// DATA_MODEL `imports.source_kind`.
public enum ImportSourceKind: String, Codable, CaseIterable, Sendable {
  case screenwatch
  case screenshots
  case videos
}

/// An import space: one import, kept apart from live data and wiped as a unit.
public struct ImportSpace: Codable, Equatable, Hashable, Sendable {
  /// `import_id` (a UUID) from `POST /v1/imports`.
  public var id: String
  public var sourceKind: ImportSourceKind

  public init(id: String, sourceKind: ImportSourceKind) {
    self.id = id
    self.sourceKind = sourceKind
  }
}

/// `POST /v1/imports` body.
public struct CreateImportRequest: Codable, Equatable, Sendable {
  public var sourceKind: ImportSourceKind
  public init(sourceKind: ImportSourceKind) { self.sourceKind = sourceKind }
  enum CodingKeys: String, CodingKey { case sourceKind = "source_kind" }
}

/// `POST /v1/imports` reply.
public struct CreateImportResponse: Codable, Equatable, Sendable {
  public var importID: String
  public init(importID: String) { self.importID = importID }
  enum CodingKeys: String, CodingKey { case importID = "import_id" }
}

/// `POST /v1/me/forget` body for one import space.
public struct ForgetImportRequest: Codable, Equatable, Sendable {
  public var scope = "import"
  public var importID: String
  public init(importID: String) { self.importID = importID }
  enum CodingKeys: String, CodingKey {
    case scope
    case importID = "import_id"
  }
}

/// One masked observation of an import (the m1-02 `Observation` kinds the import writes). Every one carries
/// `source: "import"` and its import space's id.
public struct ImportObservation: Equatable, Sendable, Encodable {
  public enum Kind: String, Sendable {
    case focus
    case idleStart = "idle_start"
    case idleEnd = "idle_end"
    case textSnapshot = "text_snapshot"
  }

  public let id: String
  public let ts: Date
  public let kind: Kind
  public let importID: String
  public let appBundleID: String?
  public let appName: String?
  public let title: String?
  public let host: String?
  public let text: String?
  public let textHash: String?

  public var source: String { "import" }

  public static func focus(id: String, ts: Date, importID: String, appBundleID: String, appName: String,
                           title: String? = nil, host: String? = nil) -> ImportObservation {
    ImportObservation(id: id, ts: ts, kind: .focus, importID: importID,
                      appBundleID: ImportWire.clip(appBundleID, maxUTF16: ImportWire.limits.appBundleID),
                      appName: ImportWire.clip(appName, maxUTF16: ImportWire.limits.appName),
                      title: title.map { ImportWire.clip($0, maxUTF16: ImportWire.limits.title) }, host: host,
                      text: nil, textHash: nil)
  }

  public static func idle(_ kind: Kind, id: String, ts: Date, importID: String) -> ImportObservation {
    ImportObservation(id: id, ts: ts, kind: kind, importID: importID, appBundleID: nil, appName: nil, title: nil,
                      host: nil, text: nil, textHash: nil)
  }

  /// A `text_snapshot` of OCR text that was already masked. The hash is of the text as sent.
  public static func text(id: String, ts: Date, importID: String, appBundleID: String, text: String) -> ImportObservation {
    let clipped = ImportWire.clip(text, maxUTF16: ImportWire.limits.text)
    return ImportObservation(id: id, ts: ts, kind: .textSnapshot, importID: importID,
                             appBundleID: ImportWire.clip(appBundleID, maxUTF16: ImportWire.limits.appBundleID),
                             appName: nil, title: nil, host: nil, text: clipped, textHash: ImportWire.sha256Hex(clipped))
  }

  enum CodingKeys: String, CodingKey {
    case id, ts, kind, source, title, host, text
    case importID = "import_id"
    case appBundleID = "app_bundle_id"
    case appName = "app_name"
    case textHash = "text_hash"
    case textSource = "text_source"
  }

  public func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(id, forKey: .id)
    try c.encode(ImportWire.rfc3339(ts), forKey: .ts)
    try c.encode(kind.rawValue, forKey: .kind)
    try c.encode(source, forKey: .source)
    try c.encode(importID, forKey: .importID)
    try c.encodeIfPresent(appBundleID, forKey: .appBundleID)
    try c.encodeIfPresent(appName, forKey: .appName)
    try c.encodeIfPresent(title, forKey: .title)
    try c.encodeIfPresent(host, forKey: .host)
    try c.encodeIfPresent(text, forKey: .text)
    try c.encodeIfPresent(textHash, forKey: .textHash)
    if kind == .textSnapshot { try c.encode("ocr", forKey: .textSource) }
  }
}

public enum ImportWire {
  /// The contract's string limits (UTF-16 code units, as JSON Schema and zod count them).
  public struct Limits: Sendable {
    public let text = 8000
    public let title = 512
    public let appName = 256
    public let appBundleID = 255
  }

  public static let limits = Limits()

  /// RFC 3339 in UTC with milliseconds: 2026-11-13T09:41:07.000Z.
  public static func rfc3339(_ date: Date) -> String {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "UTC")!
    let ms = Int64((date.timeIntervalSince1970 * 1000).rounded(.down))
    let whole = Date(timeIntervalSince1970: TimeInterval(ms.floorDiv(1000)))
    let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: whole)
    return String(format: "%04ld-%02ld-%02ldT%02ld:%02ld:%02ld.%03ldZ", c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0,
                  c.minute ?? 0, c.second ?? 0, Int(ms.floorMod(1000)))
  }

  /// SHA-256 of the UTF-8 bytes, lowercase hex (the contract's `sha256Hex`).
  public static func sha256Hex(_ text: String) -> String {
    hex(SHA256.hash(data: Data(text.utf8)))
  }

  static func hex<D: Sequence>(_ bytes: D) -> String where D.Element == UInt8 {
    bytes.map { String(format: "%02x", $0) }.joined()
  }

  /// The longest prefix of whole characters within `maxUTF16` UTF-16 code units.
  public static func clip(_ s: String, maxUTF16: Int) -> String {
    guard s.utf16.count > maxUTF16 else { return s }
    var out = ""
    var used = 0
    for ch in s {
      let n = String(ch).utf16.count
      if used + n > maxUTF16 { break }
      out.append(ch)
      used += n
    }
    return out
  }
}

extension Int64 {
  func floorDiv(_ d: Int64) -> Int64 { (self >= 0 ? self : self - d + 1) / d }
  func floorMod(_ d: Int64) -> Int64 { self - floorDiv(d) * d }
}

/// ULIDs (Crockford base 32: 48 bits of milliseconds, 80 random bits), as the contract's `id`.
public struct ULIDGenerator: Sendable {
  static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

  public init() {}

  public func next(at date: Date) -> String {
    let ms = UInt64(max(0, (date.timeIntervalSince1970 * 1000).rounded(.down)))
    var rng = SystemRandomNumberGenerator()
    let high = UInt16.random(in: .min ... .max, using: &rng)    // top 16 of the 80 random bits
    let low = UInt64.random(in: .min ... .max, using: &rng)     // the other 64
    var out: [Character] = []
    out.reserveCapacity(26)
    // 10 characters of time (50 bits, the top 2 always zero for 48-bit times).
    for i in stride(from: 9, through: 0, by: -1) { out.append(Self.alphabet[Int((ms >> (UInt64(i) * 5)) & 31)]) }
    // 16 characters of randomness: 80 bits as high (16) then low (64).
    for i in stride(from: 15, through: 0, by: -1) {
      let shift = i * 5
      let v: UInt64
      if shift >= 64 {
        v = (UInt64(high) >> UInt64(shift - 64)) & 31
      } else if shift + 5 > 64 {
        v = ((low >> UInt64(shift)) | (UInt64(high) << UInt64(64 - shift))) & 31
      } else {
        v = (low >> UInt64(shift)) & 31
      }
      out.append(Self.alphabet[Int(v)])
    }
    return String(out)
  }
}
