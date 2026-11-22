import CryptoKit
import Foundation
import Testing
@testable import OffloadImport
@testable import OffloadMac

// Person names in the interim masker (follow-up 2026-11-22): the "Name <email>" and signature-block rules of m3-02's
// `OffloadMasker.TextMasker`, plus names NaturalLanguage's tagger finds, become `<person:h_…>` before anything is stored.
// Most tests inject the name finder so the rules give the same result on every Mac; two use the real tagger.

/// Reports every occurrence of the given strings as a person name (stands in for NLTagger).
struct M310Names: PersonNameFinder {
  var names: [String]

  func personNames(in text: String) -> [Range<String.Index>] {
    var out: [Range<String.Index>] = []
    for name in names {
      var from = text.startIndex
      while from < text.endIndex, let r = text.range(of: name, range: from..<text.endIndex) {
        out.append(r)
        from = r.upperBound
      }
    }
    return out
  }
}

extension M310 {
  static func person(_ m: InterimTextMasker, _ name: String) -> String { m.personPseudonym(name) }

  @Test("MASK: a name before an email address becomes a person pseudonym and the address an email pseudonym")
  func nameBeforeAddress() {
    let m = InterimTextMasker(key: m310Key, names: M310Names(names: []))
    let email = m.pseudonym("email", "amara@example.com")
    #expect(m.mask("From: Amara Okafor <amara@example.com>") == "From: \(Self.person(m, "Amara Okafor")) <\(email)>")
  }

  @Test("MASK: a signature block's name becomes a person pseudonym; a team sign-off stays")
  func signatureBlock() {
    let m = InterimTextMasker(key: m310Key, names: M310Names(names: []))
    let mail = "Thanks for the update.\n\nBest regards,\nDaniel Kim\nAcme Ledger"
    #expect(m.mask(mail) == "Thanks for the update.\n\nBest regards,\n\(Self.person(m, "Daniel Kim"))\nAcme Ledger")
    let team = "Thanks,\nThe Support Team"
    #expect(m.mask(team) == team)
  }

  @Test("MASK: names found in OCR lines become person pseudonyms, the same name always the same pseudonym")
  func namesInOCRLines() {
    let m = InterimTextMasker(key: m310Key, names: M310Names(names: ["Amara Okafor", "AMARA OKAFOR", "Daniel Kim"]))
    let a = Self.person(m, "Amara Okafor")
    let d = Self.person(m, "Daniel Kim")
    let out = m.mask("Call with Amara Okafor at 4:00\nNotes from Daniel Kim\nAMARA OKAFOR joined")
    #expect(out == "Call with \(a) at 4:00\nNotes from \(d)\n\(a) joined")
  }

  @Test("MASK: a name in a window title is masked before the observation is made")
  func nameInTitle() throws {
    let m = InterimTextMasker(key: m310Key, names: M310Names(names: ["Amara Okafor"]))
    let row = ScreenwatchRow(t: "09-00-00", ts: M310Clock.date(2026, 11, 18, 9), app: "Google Chrome",
                             window: "Re: Invoice for Amara Okafor - Gmail", url: nil, img: true)
    let obs = ScreenwatchReader.observations(rows: [row], importID: "imp-1", masker: m, exclusions: [], ids: ULIDGenerator())
    let title = try #require(obs.first { $0.kind == .focus }?.title)
    #expect(title == "Re: Invoice for \(Self.person(m, "Amara Okafor")) - Gmail")
  }

  @Test("MASK: person pseudonyms have m3-02's shape and normalisation (lowercased, single spaces, first 16 hex of HMAC-SHA256)")
  func personPseudonymShape() {
    let m = InterimTextMasker(key: m310Key, names: M310Names(names: []))
    let p = m.personPseudonym("  Amara   OKAFOR ")
    let mac = HMAC<SHA256>.authenticationCode(for: Data("amara okafor".utf8), using: SymmetricKey(data: m310Key))
    let hex = mac.prefix(8).map { String(format: "%02x", $0) }.joined()
    #expect(p == "<person:h_\(hex)>")
    #expect(p == m.pseudonym("person", "amara okafor"))
  }

  @Test("MASK: app names, months, weekdays and common words stay, even when a tagger reports them as names")
  func nonNamesStay() {
    let m = InterimTextMasker(key: m310Key, names: M310Names(names: ["Monday", "March", "Safari", "Google Chrome", "May", "Claude"]))
    let text = "Monday, March 3: notes in Safari and Google Chrome, due in May, asked Claude"
    #expect(m.mask(text) == text)
  }

  @Test("MASK: NaturalLanguage's tagger finds common person names on its own; app names, months and common words stay")
  func realTagger() {
    let m = InterimTextMasker(key: m310Key)
    let out = m.mask("Yesterday John Smith called Mary Johnson about the quarterly report.")
    #expect(!out.contains("John Smith") && !out.contains("Mary Johnson"))
    #expect(out.contains("<person:h_"))
    #expect(out.contains("about the quarterly report."))
    for keep in ["Xcode", "Google Chrome", "Safari", "Microsoft Excel", "1Password 7", "zoom.us", "Slack", "Mail", "Claude",
                 "Monday", "March", "June", "August", "Invoice", "Inbox", "Budget review"] {
      #expect(m.mask(keep) == keep, "\(keep)")
    }
  }
}
