import CryptoKit
import Foundation
import OffloadImport

// INTERIM. The on-device masker the recordings import uses until m3-02's `OffloadMasker.TextMasker` lands (PR #13);
// then an adapter `TextMaskerImportAdapter: ImportTextMasker` calling `mask(_:).text` replaces this file and the
// local pseudonym key gives way to the tenant pseudonym key in the Keychain (SPEC, Scope changes). The labels match
// `OffloadMasker.MaskCategory`, so the swap changes no stored shape.
//
// Order (each rule test-driven, MASK tests):
//   1. URLs keep their host; the path becomes `<doc:h_…>`; query and fragment are dropped.
//   2. Tokens become `[SECRET]`.
//   3. Emails become `<email:h_…>` (before the digit rules, so an address's digits stay in its pseudonym).
//   4. Card-like numbers that pass Luhn become `[CARD NO.]`.
//   5. Phone numbers become `<phone:h_…>` (before the long-digit rule, so a phone is never read as an account).
//   6. Long digit runs become `[ACCT NO.]`; a standalone 6 or 7 digit code becomes `[OTP]`.
// The output is cut to 8000 characters after masking. Known limits: no person names, no IBAN checks (SPEC).

/// 32 random bytes in `OnDevice/pseudonym.key` (file 0600, folder 0700), created once and reused.
public enum LocalPseudonymKey {
  public static let length = 32

  public static func loadOrCreate(at file: URL) throws -> Data {
    if let data = try? Data(contentsOf: file), data.count == length { return data }
    let key = SymmetricKey(size: .bits256)
    let bytes = key.withUnsafeBytes { Data($0) }
    try OnDeviceFiles.ensureFolder(file.deletingLastPathComponent())
    try? FileManager.default.removeItem(at: file)
    try OnDeviceFiles.writeProtected(bytes, to: file)
    return bytes
  }
}

public struct InterimTextMasker: ImportTextMasker {
  public static let maxCharacters = 8000
  /// The pseudonym key's bytes (Data, so the masker is Sendable).
  private let key: Data

  public init(key: Data) { self.key = key }

  public func mask(_ text: String) -> String {
    var s = text
    s = maskURLs(s)
    s = maskSecrets(s)
    s = replace(s, #"[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}"#) { pseudonym("email", $0.lowercased()) }
    s = replace(s, #"(?<![0-9A-Za-z_-])[0-9](?:[ -]?[0-9]){12,18}(?![0-9])"#) { m in
      let digits = m.filter(\.isASCIIDigit)
      return (13...19).contains(digits.count) && Self.luhn(digits) ? "[CARD NO.]" : nil
    }
    s = replace(s, #"(?<![0-9A-Za-z_+])\+[0-9](?:[ -]?[0-9]){7,14}(?![0-9])"#) { pseudonym("phone", $0.filter(\.isASCIIDigit)) }
    s = replace(s, #"(?<![0-9A-Za-z_])\(?[0-9]{3}\)?[ .-][0-9]{3}[ .-][0-9]{4}(?![0-9])"#) { pseudonym("phone", $0.filter(\.isASCIIDigit)) }
    // A date like 2026-11-22 is never an account number.
    s = replace(s, #"(?<![0-9A-Za-z_-])(?![0-9]{4}-[0-9]{2}-[0-9]{2}(?![0-9]))[0-9](?:[ -]?[0-9]){7,}(?![0-9])"#) { _ in "[ACCT NO.]" }
    // Standalone: not inside a word, a decimal, a time or a date; a sentence's full stop may follow.
    s = replace(s, #"(?<![0-9A-Za-z_])(?<![0-9A-Za-z][.,:/-])[0-9]{6,7}(?![0-9A-Za-z_])(?![.,:/-][0-9A-Za-z])"#) { _ in "[OTP]" }
    return ImportWire.clip(s, maxUTF16: Self.maxCharacters)
  }

  // MARK: Rules

  /// `scheme://host/path?query#fragment` → `scheme://host/<doc:h_…>`; a bare `host.tld/path` the same.
  func maskURLs(_ text: String) -> String {
    var s = replace(text, #"\b[A-Za-z][A-Za-z0-9+.-]*://[^\s<>"']+"#) { m in
      let (url, trailing) = Self.splitTrailing(m)
      guard let schemeEnd = url.range(of: "://") else { return nil }
      let scheme = String(url[..<schemeEnd.lowerBound])
      let rest = String(url[schemeEnd.upperBound...])
      return "\(scheme)://\(hostAndDoc(rest))" + trailing
    }
    s = replace(s, #"(?<![@\w./:-])(?:[A-Za-z0-9-]+\.)+[A-Za-z]{2,}/[^\s<>"']*"#) { m in
      let (url, trailing) = Self.splitTrailing(m)
      return hostAndDoc(url) + trailing
    }
    return s
  }

  /// "host/path?q#f" → "host/<doc:h_…>"; "host", "host/" or "host?q" → "host".
  func hostAndDoc(_ rest: String) -> String {
    let cut = rest.firstIndex { $0 == "/" || $0 == "?" || $0 == "#" } ?? rest.endIndex
    let hostPart = String(rest[..<cut])
    var path = ""
    if cut < rest.endIndex, rest[cut] == "/" {
      let afterHost = rest[cut...]
      let end = afterHost.firstIndex { $0 == "?" || $0 == "#" } ?? afterHost.endIndex
      path = String(afterHost[..<end])
    }
    let host = hostPart.lowercased()
    guard !path.isEmpty, path != "/" else { return host }
    return "\(host)/\(pseudonym("doc", (host + path).lowercased()))"
  }

  func maskSecrets(_ text: String) -> String {
    var s = text
    s = replace(s, #"-----BEGIN [A-Z ]*PRIVATE KEY-----(?:[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----|[\s\S]*$)"#) { _ in "[SECRET]" }
    let families = [
      #"\bsk-(?:ant-)?[A-Za-z0-9_-]{16,}"#,
      #"\b(?:ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{20,}"#,
      #"\bgithub_pat_[A-Za-z0-9_]{20,}"#,
      #"\bxox[abpr]-[A-Za-z0-9-]{10,}"#,
      #"\bAKIA[0-9A-Z]{16}\b"#,
      #"\beyJ[A-Za-z0-9_-]{5,}\.[A-Za-z0-9_-]{5,}\.[A-Za-z0-9_-]{5,}"#,
    ]
    for p in families { s = replace(s, p) { _ in "[SECRET]" } }
    // Any run of 32 or more key characters that mixes letters and digits.
    s = replace(s, #"[A-Za-z0-9_+/=-]{32,}"#) { m in
      m.contains(where: \.isLetter) && m.contains(where: \.isASCIIDigit) ? "[SECRET]" : nil
    }
    return s
  }

  /// `<kind:h_` + first 16 hex of HMAC-SHA256(normalised value) under the local pseudonym key `>`.
  public func pseudonym(_ kind: String, _ normalised: String) -> String {
    let mac = HMAC<SHA256>.authenticationCode(for: Data(normalised.utf8), using: SymmetricKey(data: key))
    let hex = mac.map { String(format: "%02x", $0) }.joined()
    return "<\(kind):h_\(hex.prefix(16))>"
  }

  static func luhn(_ digits: String) -> Bool {
    var sum = 0
    for (i, ch) in digits.reversed().enumerated() {
      guard var d = ch.wholeNumberValue else { return false }
      if i % 2 == 1 {
        d *= 2
        if d > 9 { d -= 9 }
      }
      sum += d
    }
    return sum % 10 == 0
  }

  /// A URL in running text often ends with punctuation that is not part of it.
  static func splitTrailing(_ m: String) -> (String, String) {
    var url = m
    var trailing = ""
    while let last = url.last, ".,;:!?)]}".contains(last) {
      trailing = String(last) + trailing
      url.removeLast()
    }
    return (url, trailing)
  }

  /// Replaces every match of `pattern` (from the end, so ranges stay valid). `transform` returns nil to keep a match.
  func replace(_ text: String, _ pattern: String, _ transform: (String) -> String?) -> String {
    guard let re = try? NSRegularExpression(pattern: pattern, options: []) else { return text }
    let ns = text as NSString
    let matches = re.matches(in: text, options: [], range: NSRange(location: 0, length: ns.length))
    guard !matches.isEmpty else { return text }
    let out = NSMutableString(string: text)
    for m in matches.reversed() {
      let found = ns.substring(with: m.range)
      if let replacement = transform(found) { out.replaceCharacters(in: m.range, with: replacement) }
    }
    return out as String
  }
}

extension Character {
  var isASCIIDigit: Bool { isASCII && isNumber }
}
