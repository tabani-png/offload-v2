import Foundation
import Testing
@testable import OffloadImport

// App cues inside the ingest path: used only when the menu bar reader gives nothing; a focus per app or host change;
// exclusions still win; nothing unmasked leaves in a focus field.
extension M305C {
  // MARK: SIGNALS

  /// A 60 s window recording (no menu bar): Gmail, Gmail again, QuickBooks, a portal, another site.
  static func windowRecording(_ id: String = "window") -> M305Script {
    M305Script(id: id, duration: 60, scenes: [
      M305Scene(at: 0, lines: m305cWindow(tab: "Inbox - Gmail", url: "https://mail.google.com/mail/u/0/#inbox",
                                          body: "Invoice 1042 from Acme"), hash: 0),
      M305Scene(at: 10, lines: m305cWindow(tab: "Inbox - Gmail", url: "https://mail.google.com/mail/u/0/#inbox",
                                           body: "Invoice 1042 from Acme"), hash: 0),
      M305Scene(at: 20, lines: m305cWindow(tab: "Invoices | QuickBooks", url: "qbo.intuit.com/app/invoices",
                                           body: "Create invoice"), hash: 0xFF),
      M305Scene(at: 40, lines: m305cWindow(url: "portal.acme-supplies.com/orders", body: "Order list"), hash: 0xFF00),
      M305Scene(at: 50, lines: m305cWindow(url: "www.example.org/help", body: "Help"), hash: 0xFF0000),
    ])
  }

  @Test("SIGNALS: a recording without a menu bar gets its app and host from the window chrome, one focus per change")
  func windowRecordingGetsCues() throws {
    let r = try M305C.ingest(M305C.windowRecording())
    let focus = M305.of(.focus, r)
    #expect(focus.map(\.appName) == ["Gmail", "QuickBooks", "Browser", "Browser"])
    #expect(focus.map(\.appBundleID) == ["web.gmail", "web.quickbooks", "recording.browser", "recording.browser"])
    #expect(focus.map(\.host) == ["mail.google.com", "qbo.intuit.com", "portal.acme-supplies.com", "www.example.org"])
    let start = M305Clock.now.addingTimeInterval(-3600)
    #expect(focus.map(\.ts) == [0, 20, 40, 50].map { start.addingTimeInterval($0) })
    #expect(!focus.contains { $0.appBundleID == "recording.unknown" })
    // Text snapshots carry the cue's app too.
    let text = M305.of(.textSnapshot, r)
    #expect(text.first?.appBundleID == "web.gmail")
    #expect(text.map(\.appBundleID).contains("web.quickbooks"))
  }

  @Test("SIGNALS: the menu bar wins; cues are read only when the menu bar reader gives nothing")
  func menuBarWins() throws {
    let lines = m305Screen(app: "Safari", body: "Inbox") + [m305cLine("mail.google.com/mail/u/0", y: 50, x: 200)]
    let r = try M305C.ingest(M305.oneScene("safari", lines))
    let focus = M305.of(.focus, r)
    #expect(focus.map(\.appName) == ["Safari"])
    #expect(focus.map(\.appBundleID) == ["com.apple.Safari"])
    #expect(focus.map(\.host) == [nil])
    // A menu bar name the masker would change is no menu bar app: then the cue applies.
    let masked = m305Screen(app: "Report 2026", menus: "File Edit View", body: "Totals") + [m305cLine("Totals - Google Sheets", y: 60)]
    let m = try M305C.ingest(M305.oneScene("masked", masked))
    #expect(M305.of(.focus, m).map(\.appName) == ["Google Sheets"])
  }

  @Test("SIGNALS: an excluded host or app keeps a focus with the app name only, and no host, text or keyframe")
  func exclusionsStillWin() throws {
    let bank = M305.oneScene("bank", m305cWindow(url: "https://secure.chase.com/accounts", body: "Balance 9876"))
    let portal = M305.oneScene("portal", m305cWindow(url: "portal.acme-supplies.com/orders", body: "Order list"))
    let slack = M305.oneScene("slack", m305cWindow(tab: "general - Slack", body: "Lunch on Friday?"))
    let rules = [ImportExclusionRule(kind: .host, value: "acme-supplies.com"),
                 ImportExclusionRule(kind: .bundleID, value: "com.tinyspeck.slackmacgap")]
    for (script, name) in [(bank, "Browser"), (portal, "Browser"), (slack, "Slack")] {
      let keyframes = FakeKeyframes()
      let r = try M305C.ingest(script, keyframes: keyframes, exclusions: rules)
      let focus = M305.of(.focus, r)
      #expect(focus.map(\.appName) == [name], "\(script.id)")
      #expect(focus.allSatisfy { $0.host == nil && $0.title == nil }, "\(script.id)")
      #expect(M305.of(.textSnapshot, r).isEmpty, "\(script.id)")
      #expect(keyframes.all.isEmpty, "\(script.id)")
    }
  }

  @Test("SIGNALS: nothing unmasked leaves in a focus: names are table constants, a host is one the masker left unchanged")
  func nothingUnmaskedInFocus() throws {
    let script = M305Script(id: "pii", duration: 30, scenes: [
      M305Scene(at: 0, lines: m305cWindow(tab: "Amara Okafor - Gmail", url: "https://mail.google.com/mail/u/0/#inbox/FMfcgz4411",
                                          body: "Reply to Amara Okafor about card 4111 1111"), hash: 0),
      M305Scene(at: 10, lines: m305cWindow(tab: "Okafor 2026 budget", url: "https://crm4411.example.com/people/okafor",
                                           body: "Budget"), hash: 0),
      M305Scene(at: 20, lines: m305cWindow(tab: "Okafor_contract.pdf", body: "Terms"), hash: 0),
    ])
    let masker = FakeMasker()
    let r = try M305C.ingest(script, masker: masker)
    let focus = M305.of(.focus, r)
    #expect(focus.map(\.appName) == ["Gmail", "Screen"])
    #expect(focus.map(\.host) == ["mail.google.com", nil])
    let json = String(decoding: try JSONEncoder().encode(focus), as: UTF8.self)
    for raw in ["Okafor", "okafor", "Amara", "4411", "FMfcgz", "/mail", "inbox", "budget", "contract", "crm"] {
      #expect(!json.contains(raw), "\(raw)")
    }
    for f in focus {
      #expect(M305C.cueNames.contains(f.appName ?? "") || f.appName == "Screen")
    }
    // Text snapshots are the masker's output only.
    #expect(M305.of(.textSnapshot, r).allSatisfy { !($0.text ?? "").contains("Okafor") && !($0.text ?? "").contains("4411") })
    #expect(masker.calls.contains("mail.google.com"))
  }

  @Test("SIGNALS: two unrelated window recordings get different app keys instead of one Screen bucket")
  func unrelatedRecordingsStayApart() throws {
    let invoices = M305Script(id: "invoices", duration: 30, scenes: [
      M305Scene(at: 0, lines: m305cWindow(tab: "Invoices | QuickBooks", url: "qbo.intuit.com/app/invoices", body: "Create invoice"), hash: 0),
    ])
    let crm = M305Script(id: "crm", duration: 30, scenes: [
      M305Scene(at: 0, lines: m305cWindow(tab: "Contacts | HubSpot", body: "Deals"), hash: 0),
    ])
    let a = Set(M305.of(.focus, try M305C.ingest(invoices)).compactMap(\.appBundleID))
    let b = Set(M305.of(.focus, try M305C.ingest(crm)).compactMap(\.appBundleID))
    #expect(a == ["web.quickbooks"])
    #expect(b == ["web.hubspot"])
    #expect(a.isDisjoint(with: b))
  }
}
