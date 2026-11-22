import CryptoKit
import Foundation
import Testing

@testable import OffloadContracts
@testable import OffloadMasker
@testable import OffloadStore

extension M302 {
    static func masker(key byte: UInt8 = 7) -> TextMasker {
        TextMasker(pseudonymizer: Pseudonymizer(key: PseudonymKey(data: Data(repeating: byte, count: 32))))
    }

    static let pseudonymPattern = try! NSRegularExpression(pattern: #"<(person|email|phone|doc):h_[0-9a-f]{16}>"#)

    static func pseudonyms(in text: String) -> [String] {
        pseudonymPattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).map {
            String(text[Range($0.range, in: text)!])
        }
    }

    @Test("PSEUDO: the same email on two days gets the same pseudonym")
    func sameEmailSamePseudonym() {
        let m = Self.masker()
        let monday = m.mask("Please forward this to Jane.Doe@Example.com before noon.").text
        let friday = m.mask("Re: invoice, cc jane.doe@example.com").text
        let a = Self.pseudonyms(in: monday)
        let b = Self.pseudonyms(in: friday)
        #expect(a.count == 1 && b.count == 1)
        #expect(a == b)
        #expect(a.first?.hasPrefix("<email:h_") == true)
        #expect(!monday.lowercased().contains("jane.doe"))
        // The shape and the value: HMAC-SHA256(key, normalised value), first 16 hex.
        let mac = HMAC<SHA256>.authenticationCode(for: Data("jane.doe@example.com".utf8), using: SymmetricKey(data: Data(repeating: 7, count: 32)))
        let hex = mac.map { String(format: "%02x", $0) }.joined().prefix(16)
        #expect(a.first == "<email:h_\(hex)>")
    }

    @Test("PSEUDO: two tenants' keys give different pseudonyms for the same value")
    func tenantsDiffer() {
        let one = Self.masker(key: 1).mask("write to ops@acme.example").text
        let two = Self.masker(key: 2).mask("write to ops@acme.example").text
        #expect(Self.pseudonyms(in: one).count == 1)
        #expect(Self.pseudonyms(in: one) != Self.pseudonyms(in: two))
        // Normalisation rules of ADR 0028.
        let p = Pseudonymizer(key: PseudonymKey(data: Data(repeating: 1, count: 32)))
        #expect(p.pseudonym(.phone, value: "+1 (416) 555-0100") == p.pseudonym(.phone, value: "14165550100"))
        #expect(p.pseudonym(.person, value: "  Jane   DOE ") == p.pseudonym(.person, value: "jane doe"))
        #expect(p.pseudonym(.doc, value: "Docs.Example.com/A/B") == p.pseudonym(.doc, value: "docs.example.com/a/b"))
    }

    @Test("PSEUDO: a URL keeps its host, its path becomes a doc pseudonym and the query is dropped")
    func urlKeepsHostOnly() {
        let m = Self.masker()
        let out = m.mask("see https://docs.google.com/spreadsheets/d/1AbCdEf/edit?usp=sharing&gid=7#range=A1 for details").text
        #expect(out.contains("docs.google.com"))
        #expect(!out.contains("1AbCdEf") && !out.contains("spreadsheets") && !out.contains("usp") && !out.contains("gid") && !out.contains("range"))
        let found = Self.pseudonyms(in: out)
        #expect(found.count == 1 && found.first?.hasPrefix("<doc:h_") == true)
        // Same document, different query: same pseudonym. Same host, other document: another one.
        let again = m.mask("https://docs.google.com/spreadsheets/d/1AbCdEf/edit?other=1").text
        let other = m.mask("https://docs.google.com/spreadsheets/d/ZZZ/edit").text
        #expect(Self.pseudonyms(in: again) == found)
        #expect(Self.pseudonyms(in: other) != found)
        // A bare host has no path and no pseudonym.
        #expect(Self.pseudonyms(in: m.mask("https://example.com").text).isEmpty)
        // The focus fields come from the same rule.
        let parts = m.maskURL("https://docs.google.com/spreadsheets/d/1AbCdEf/edit?usp=sharing")
        #expect(parts?.host == "docs.google.com")
        #expect(parts?.doc == found.first)
    }

    @Test("PSEUDO: a person name in a signature block becomes a person pseudonym")
    func signatureNameBecomesPseudonym() {
        let m = Self.masker()
        let body = "Thanks for sending the file over.\n\nBest regards,\nJane Smith\nController, Acme Corp\n"
        let out = m.mask(body)
        #expect(!out.text.contains("Jane") && !out.text.contains("Smith"))
        let found = Self.pseudonyms(in: out.text)
        #expect(found.count == 1 && found.first?.hasPrefix("<person:h_") == true)
        #expect(out.text.contains("Acme Corp"))
        #expect(out.reveals[found.first ?? ""] == "Jane Smith")
        // The same name elsewhere in the text, and "Name <email>" headers, map to the same person.
        let again = m.mask("Cheers,\nJANE SMITH").text
        #expect(Self.pseudonyms(in: again) == found)
    }

    @Test("PSEUDO: the reveal map resolves a pseudonym on the device and is purged after 7 days")
    func revealMapResolvesAndPurges() throws {
        let home = TestHome()
        let m = Self.masker()
        let out = m.mask("Forward to jane.doe@example.com")
        let pseudonym = try #require(Self.pseudonyms(in: out.text).first)
        let map = RevealMap(layout: home.layout, keys: home.keys, days: home.days)
        try map.record(out.reveals, at: t0)
        #expect(map.resolve(pseudonym) == "jane.doe@example.com")
        // A new process reads the same sealed file.
        let reopened = RevealMap(layout: home.layout, keys: home.keys, days: home.days)
        #expect(reopened.resolve(pseudonym) == "jane.doe@example.com")
        // The value is not in the file in the clear.
        let raw = try Data(contentsOf: home.layout.revealFile)
        #expect(raw.range(of: Data("jane.doe".utf8)) == nil)
        // Day 7 still resolves; day 8 purges.
        #expect(try reopened.purge(now: t0.addingTimeInterval(7 * 86_400)) == 0)
        #expect(reopened.resolve(pseudonym) != nil)
        #expect(try reopened.purge(now: t0.addingTimeInterval(8 * 86_400)) == 1)
        #expect(reopened.resolve(pseudonym) == nil)
    }
}
