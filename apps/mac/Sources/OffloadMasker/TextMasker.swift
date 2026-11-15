// The on-device masker (ARCHITECTURE section 1, ADR 0005, ADR 0028). Order of work on one text:
//  1. structured secrets are destroyed (cards, bank numbers, IBAN, government ids, one-time codes, keys: SensitiveDetector);
//  2. URLs keep their host, the path becomes a doc pseudonym, query and fragment are dropped;
//  3. emails, phone numbers and person names (signature blocks, "Name <email>") become pseudonyms;
//  4. the result is cut to `maxCharacters`.
// Every pseudonym is returned with the value it stands for so the device can keep its reveal map (never uploaded).
import Foundation

public struct MaskOutcome: Equatable, Sendable {
    public var text: String
    /// Masks applied, by kind: the detector categories (`PAN`, `IBAN`, ...) and `url`, `email`, `phone`, `person`.
    public var counts: [String: Int]
    /// pseudonym -> the value it replaced.
    public var reveals: [String: String]
}

public struct MaskedURL: Equatable, Sendable {
    public var host: String
    public var doc: String?
    /// What stands in the text for the URL.
    public var rendered: String
    public var reveals: [String: String]
}

public struct TextMasker: Sendable {
    public let pseudonymizer: Pseudonymizer
    public let maxCharacters: Int
    private let secrets = Masker()

    public init(pseudonymizer: Pseudonymizer, maxCharacters: Int = 8000) {
        self.pseudonymizer = pseudonymizer
        self.maxCharacters = maxCharacters
    }

    /// A window title: masked like text, at most 512 characters (the schema bound).
    public func maskTitle(_ title: String) -> MaskOutcome {
        var out = mask(title, limit: 512)
        out.text = out.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return out
    }

    public func mask(_ text: String) -> MaskOutcome { mask(text, limit: maxCharacters) }

    func mask(_ text: String, limit: Int) -> MaskOutcome {
        let secret = secrets.mask(text)
        var counts: [String: Int] = [:]
        for (category, n) in secret.counts { counts[category.rawValue] = n }
        var reveals: [String: String] = [:]
        let t1 = secret.text

        var candidates: [Candidate] = []
        let ns = t1 as NSString
        let whole = NSRange(location: 0, length: ns.length)

        for m in Patterns.url.matches(in: t1, range: whole) {
            var range = m.range
            // Trailing sentence punctuation is not part of the URL.
            while range.length > 0, ".,;:!?)]}".contains(ns.substring(with: NSRange(location: range.location + range.length - 1, length: 1))) {
                range.length -= 1
            }
            let raw = ns.substring(with: range)
            if let masked = maskURL(raw) {
                candidates.append(Candidate(range: range, replacement: masked.rendered, priority: 80, kind: "url", reveals: masked.reveals))
            } else {
                candidates.append(Candidate(range: range, replacement: "[URL]", priority: 80, kind: "url", reveals: [:]))
            }
        }
        for m in Patterns.email.matches(in: t1, range: whole) {
            let value = ns.substring(with: m.range)
            let p = pseudonymizer.pseudonym(.email, value: value)
            candidates.append(Candidate(range: m.range, replacement: p, priority: 70, kind: "email", reveals: [p: value]))
        }
        for m in Patterns.nameBeforeAddress.matches(in: t1, range: whole) where m.numberOfRanges > 1 {
            candidates.append(person(ns, m.range(at: 1), priority: 60))
        }
        for m in Patterns.signature.matches(in: t1, range: whole) where m.numberOfRanges > 1 {
            let r = m.range(at: 1)
            if r.location != NSNotFound, Self.looksLikeName(ns.substring(with: r)) { candidates.append(person(ns, r, priority: 60)) }
        }
        for r in Self.phoneRanges(in: t1) {
            let value = ns.substring(with: r)
            let p = pseudonymizer.pseudonym(.phone, value: value)
            candidates.append(Candidate(range: r, replacement: p, priority: 50, kind: "phone", reveals: [p: value]))
        }

        // Highest priority first, then earliest; drop anything that overlaps a kept range.
        var kept: [Candidate] = []
        for c in candidates.sorted(by: { $0.priority != $1.priority ? $0.priority > $1.priority : $0.range.location < $1.range.location }) {
            if kept.contains(where: { NSIntersectionRange($0.range, c.range).length > 0 }) { continue }
            kept.append(c)
        }
        kept.sort { $0.range.location < $1.range.location }
        var result = ""
        var cursor = 0
        for c in kept {
            result += ns.substring(with: NSRange(location: cursor, length: c.range.location - cursor))
            result += c.replacement
            cursor = c.range.location + c.range.length
            counts[c.kind, default: 0] += 1
            for (k, v) in c.reveals { reveals[k] = v }
        }
        result += ns.substring(from: cursor)
        return MaskOutcome(text: Self.truncate(result, toUTF16: limit), counts: counts, reveals: reveals)
    }

    /// `https://host/<doc:h_…>` for a URL with a path, `https://host` without one; nil when it has no host.
    public func maskURL(_ raw: String) -> MaskedURL? {
        guard let parts = URLComponents(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              let rawHost = parts.host, !rawHost.isEmpty else { return nil }
        var host = rawHost.lowercased()
        while host.hasSuffix(".") { host.removeLast() }
        guard !host.isEmpty else { return nil }
        let scheme = (parts.scheme ?? "https").lowercased()
        let path = parts.percentEncodedPath
        guard path.count > 1 else { return MaskedURL(host: host, doc: nil, rendered: "\(scheme)://\(host)", reveals: [:]) }
        let value = host + path
        let doc = pseudonymizer.pseudonym(.doc, value: value)
        return MaskedURL(host: host, doc: doc, rendered: "\(scheme)://\(host)/\(doc)", reveals: [doc: value])
    }

    // MARK: pieces

    private struct Candidate {
        var range: NSRange
        var replacement: String
        var priority: Int
        var kind: String
        var reveals: [String: String]
    }

    private func person(_ ns: NSString, _ range: NSRange, priority: Int) -> Candidate {
        let value = ns.substring(with: range)
        let p = pseudonymizer.pseudonym(.person, value: value)
        return Candidate(range: range, replacement: p, priority: priority, kind: "person", reveals: [p: value])
    }

    private static let notNameWords: Set<String> = [
        "inc", "llc", "ltd", "corp", "co", "gmbh", "plc", "the", "team", "department", "group", "support", "sent", "from", "my", "iphone", "ipad",
    ]

    static func looksLikeName(_ s: String) -> Bool {
        let tokens = s.split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard (2...4).contains(tokens.count), s.count <= 48 else { return false }
        return !tokens.contains { notNameWords.contains($0.lowercased().trimmingCharacters(in: .punctuationCharacters)) }
    }

    static func truncate(_ s: String, toUTF16 limit: Int) -> String {
        guard s.utf16.count > limit else { return s }
        var scalars = String.UnicodeScalarView()
        var used = 0
        for scalar in s.unicodeScalars {
            let w = scalar.value > 0xFFFF ? 2 : 1
            if used + w > limit { break }
            scalars.append(scalar)
            used += w
        }
        return String(scalars)
    }

    /// Phone numbers: a `+` number of 8 to 15 digits, or 10 to 15 digits with a separator that is not part of a date,
    /// an IPv4 address or a list of years.
    static func phoneRanges(in text: String) -> [NSRange] {
        // ISO dates are blanked first (same length) so "2026-11-14 10:30" is not read as a number.
        var scan = text
        let whole = NSRange(text.startIndex..., in: text)
        for m in Patterns.isoDate.matches(in: text, range: whole).reversed() {
            if let r = Range(m.range, in: scan) { scan.replaceSubrange(r, with: String(repeating: "x", count: m.range.length)) }
        }
        let ns = scan as NSString
        var out: [NSRange] = []
        for m in Patterns.phoneRun.matches(in: scan, range: NSRange(location: 0, length: ns.length)) {
            var range = m.range
            var run = ns.substring(with: range)
            // A run does not end in a separator.
            while let last = run.last, !last.isNumber { run.removeLast(); range.length -= 1 }
            let digits = run.filter { $0.isASCII && $0.isNumber }.count
            if run.hasPrefix("+") {
                if (8...15).contains(digits) { out.append(range) }
                continue
            }
            guard (10...15).contains(digits) else { continue }
            if run.range(of: #"^\d{1,3}(\.\d{1,3}){3}$"#, options: .regularExpression) != nil { continue }
            let hasMark = run.contains("(") || run.contains("-") || run.contains(".")
            let spaced = run.range(of: #"^\d{3} \d{3} \d{4}$|^\d{3} \d{4}$"#, options: .regularExpression) != nil
            if hasMark || spaced { out.append(range) }
        }
        return out
    }

    private enum Patterns {
        static let url = regex(#"[A-Za-z][A-Za-z0-9+.-]{1,15}://[^\s<>"'`]+"#)
        static let email = regex(#"[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+"#)
        static let nameBeforeAddress = regex(#"([A-Z][A-Za-z'’.-]+(?:[ \t]+[A-Z][A-Za-z'’.-]+){1,3})[ \t]*<[^<>\s]+@[^<>\s]+>"#)
        static let signature = regex(
            #"(?m)^[ \t]*(?i:best regards|kind regards|warm regards|with regards|regards|best wishes|best|thanks|thank you|many thanks|cheers|sincerely|yours sincerely|yours truly|respectfully|cordially)[ \t]*[,.!]?[ \t]*\r?\n?[ \t]*([A-Z][A-Za-z'’.-]*(?:[ \t]+[A-Z][A-Za-z'’.-]*){1,3})[ \t]*(?=\r?\n|$)"#)
        static let isoDate = regex(#"\b\d{4}-\d{2}-\d{2}\b"#)
        static let phoneRun = regex(#"\+?\(?\d(?:[ .()-]*\d)+"#)

        static func regex(_ pattern: String) -> NSRegularExpression {
            do { return try NSRegularExpression(pattern: pattern) } catch { preconditionFailure("bad masker pattern \(pattern)") }
        }
    }
}

extension NSRegularExpression {
    fileprivate func matches(in text: String, range: NSRange) -> [NSTextCheckingResult] {
        matches(in: text, options: [], range: range)
    }
}
