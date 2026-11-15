// The device's second look at text that should already be masked: the same rules as the server's transport scan
// (packages/masking/src/detectors.ts, ADR 0035). The uploader runs it on every outgoing object and fails closed.
// Pseudonyms and router placeholders are removed before scanning. Names are not scanned (the device pseudonymises them).
import Foundation

public enum LeakScan {
    /// Detector names, in the order they are tried: a more specific rule names the leak before a general one.
    public static let detectorNames = ["email", "key", "iban", "card", "url", "phone"]

    /// The first detector that fires on `text`, or nil.
    public static func scan(_ text: String) -> String? {
        var t = text
        t = replace(allowedToken, in: t, with: "\n")
        t = replace(isoDate, in: t, with: "\n")
        if email.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)) != nil { return "email" }
        if keys.contains(where: { $0.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)) != nil }) { return "key" }
        if hasIBAN(t) { return "iban" }
        if hasCard(t) { return "card" }
        if hasURLWithDetail(t) { return "url" }
        if hasPhone(t) { return "phone" }
        return nil
    }

    /// `<kind:...>` tokens left after pseudonyms and router placeholders are removed (NFKC first, so full-width brackets
    /// cannot hide one).
    public static func disallowedTokens(_ text: String) -> [String] {
        let t = replace(allowedToken, in: text.precomposedStringWithCompatibilityMapping, with: "")
        return anyToken.matches(in: t, range: NSRange(t.startIndex..., in: t)).compactMap { Range($0.range, in: t).map { String(t[$0]) } }
    }

    // MARK: rules

    private static func re(_ p: String) -> NSRegularExpression {
        do { return try NSRegularExpression(pattern: p) } catch { preconditionFailure("bad leak pattern \(p)") }
    }

    private static func replace(_ r: NSRegularExpression, in s: String, with w: String) -> String {
        r.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: w)
    }

    private static let allowedToken = re(#"<(?:(?:person|email|phone|doc):h_[0-9a-f]{16}|person:[a-z]{4}\.(?:[0-9]+(?:\.first)?|me))>"#)
    private static let anyToken = re(#"<[^<>]*:[^<>]*>"#)
    private static let isoDate = re(#"\b\d{4}-\d{2}-\d{2}\b"#)
    private static let email = re(#"[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+"#)
    private static let keys: [NSRegularExpression] = [
        #"\bsk-ant-[A-Za-z0-9_-]{20,}"#, #"\bsk-[A-Za-z0-9_-]{20,}"#, #"\bgh[pousr]_[A-Za-z0-9]{30,}"#,
        #"\bgithub_pat_[A-Za-z0-9_]{20,}"#, #"\b(?:AKIA|ASIA)[0-9A-Z]{16}\b"#, #"\bxox[abpr]-[A-Za-z0-9-]{10,}"#,
        #"\beyJ[A-Za-z0-9_-]{5,}\.[A-Za-z0-9_-]{5,}\.[A-Za-z0-9_-]{5,}"#, #"-----BEGIN [A-Z0-9 ]+-----"#,
        #"\bBearer [A-Za-z0-9._~+/=-]{16,}"#,
    ].map(re)

    private static let ibanLength: [String: Int] = [
        "AD": 24, "AE": 23, "AL": 28, "AT": 20, "AZ": 28, "BA": 20, "BE": 16, "BG": 22, "BH": 22, "BR": 29, "BY": 28, "CH": 21,
        "CR": 22, "CY": 28, "CZ": 24, "DE": 22, "DK": 18, "DO": 28, "EE": 20, "EG": 29, "ES": 24, "FI": 18, "FO": 18, "FR": 27,
        "GB": 22, "GE": 22, "GI": 23, "GL": 18, "GR": 27, "GT": 28, "HR": 21, "HU": 28, "IE": 22, "IL": 23, "IQ": 23, "IS": 26,
        "IT": 27, "JO": 30, "KW": 30, "KZ": 20, "LB": 28, "LC": 32, "LI": 21, "LT": 20, "LU": 20, "LV": 21, "MC": 27, "MD": 24,
        "ME": 22, "MK": 19, "MR": 27, "MT": 31, "MU": 30, "NL": 18, "NO": 15, "PK": 24, "PL": 28, "PS": 29, "PT": 25, "QA": 29,
        "RO": 24, "RS": 22, "SA": 24, "SC": 31, "SE": 24, "SI": 19, "SK": 24, "SM": 27, "ST": 25, "SV": 28, "TL": 23, "TN": 24,
        "TR": 26, "UA": 29, "VA": 22, "VG": 24, "XK": 20,
    ]
    private static let ibanCandidate = re(#"(?<![A-Za-z0-9])[A-Z]{2}\d{2}(?: ?[A-Z0-9]{4}){2,7}(?: ?[A-Z0-9]{1,3})?(?![A-Za-z0-9])"#)
    private static let cardRun = re(#"(?<!\d)\d(?:[ -]?\d){12,18}(?!\d)"#)
    private static let urlRun = re(#"[A-Za-z][A-Za-z0-9+.-]{1,15}://([^\s<>"'`)\]]*)"#)
    private static let phoneRun = re(#"\+?\(?\d(?:[ .()-]*\d)+"#)

    private static func hasIBAN(_ t: String) -> Bool {
        let ns = t as NSString
        for m in ibanCandidate.matches(in: t, range: NSRange(location: 0, length: ns.length)) {
            let compact = ns.substring(with: m.range).replacingOccurrences(of: " ", with: "")
            guard let want = ibanLength[String(compact.prefix(2))], compact.count >= want else { continue }
            if mod97(String(compact.prefix(want))) { return true }
        }
        return false
    }

    private static func mod97(_ compact: String) -> Bool {
        let moved = Array(compact.dropFirst(4) + compact.prefix(4))
        var rem = 0
        for ch in moved {
            guard let a = ch.asciiValue else { return false }
            let v = a >= 65 ? Int(a) - 55 : Int(a) - 48
            rem = (v < 10 ? rem * 10 + v : rem * 100 + v) % 97
        }
        return rem == 1
    }

    private static func luhn(_ digits: [Int]) -> Bool {
        var sum = 0
        var double = false
        for d in digits.reversed() {
            var v = d
            if double { v *= 2; if v > 9 { v -= 9 } }
            sum += v
            double.toggle()
        }
        return sum % 10 == 0
    }

    private static func hasCard(_ t: String) -> Bool {
        let ns = t as NSString
        for m in cardRun.matches(in: t, range: NSRange(location: 0, length: ns.length)) {
            let digits = ns.substring(with: m.range).compactMap { $0.wholeNumberValue }
            if (13...19).contains(digits.count), luhn(digits) { return true }
        }
        return false
    }

    private static func hasURLWithDetail(_ t: String) -> Bool {
        let ns = t as NSString
        for m in urlRun.matches(in: t, range: NSRange(location: 0, length: ns.length)) where m.numberOfRanges > 1 {
            let rest = ns.substring(with: m.range(at: 1))
            guard let i = rest.firstIndex(where: { "/?#".contains($0) }) else { continue }
            if rest[i...] != "/" { return true }
        }
        return false
    }

    private static func hasPhone(_ t: String) -> Bool {
        let ns = t as NSString
        for m in phoneRun.matches(in: t, range: NSRange(location: 0, length: ns.length)) {
            let run = ns.substring(with: m.range)
            let digits = run.filter { $0.isASCII && $0.isNumber }.count
            if run.hasPrefix("+") {
                if (8...15).contains(digits) { return true }
                continue
            }
            if digits < 10 || digits > 15 || !run.contains(where: { " .()-".contains($0) }) { continue }
            if run.range(of: #"^\d{1,3}(\.\d{1,3}){3}$"#, options: .regularExpression) != nil { continue }
            return true
        }
        return false
    }
}

extension NSRegularExpression {
    fileprivate func matches(in text: String, range: NSRange) -> [NSTextCheckingResult] {
        matches(in: text, options: [], range: range)
    }

    fileprivate func firstMatch(in text: String, range: NSRange) -> NSTextCheckingResult? {
        firstMatch(in: text, options: [], range: range)
    }
}
