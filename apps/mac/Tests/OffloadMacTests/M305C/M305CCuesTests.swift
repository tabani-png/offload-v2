import Foundation
import Testing
@testable import OffloadImport

// The app cue classifier: a pure, table-driven read of the window chrome (URL-bar hosts, known window titles) for
// frames without a macOS menu bar. Names come only from the table; the only frame text a cue keeps is a host the
// masker leaves unchanged.
extension M305C {
  // MARK: CUES

  @Test("CUES: a URL-bar host names a known web app, by host or by host and path prefix")
  func hostNamesKnownApp() {
    let gmail = M305C.cue(m305cWindow(url: "https://mail.google.com/mail/u/0/#inbox", body: "Inbox"))
    #expect(gmail == AppCue(appName: "Gmail", appBundleID: "web.gmail", host: "mail.google.com", ruleID: "gmail"))
    let sheets = M305C.cue(m305cWindow(url: "docs.google.com/spreadsheets/d/abc/edit#gid=0", body: "Vendors"))
    #expect(sheets == AppCue(appName: "Google Sheets", appBundleID: "web.google-sheets", host: "docs.google.com",
                             ruleID: "google-sheets"))
    #expect(M305C.cue(m305cWindow(url: "docs.google.com/document/d/abc/edit", body: "Notes"))?.appName == "Google Docs")
    let qbo = M305C.cue(m305cWindow(url: "https://qbo.intuit.com/app/invoices", body: "Invoices"))
    #expect(qbo == AppCue(appName: "QuickBooks", appBundleID: "web.quickbooks", host: "qbo.intuit.com", ruleID: "quickbooks"))
    let hub = M305C.cue(m305cWindow(url: "app.hubspot.com/contacts/objects", body: "Contacts"))
    #expect(hub == AppCue(appName: "HubSpot", appBundleID: "web.hubspot", host: "app.hubspot.com", ruleID: "hubspot"))
    let slack = M305C.cue(m305cWindow(url: "https://app.slack.com/client/TABC/CDEF", body: "general"))
    #expect(slack == AppCue(appName: "Slack", appBundleID: "com.tinyspeck.slackmacgap", host: "app.slack.com", ruleID: "slack"))
  }

  @Test("CUES: an unknown URL-bar host gives the app Browser with that host, so different sites stay apart")
  func unknownHostIsBrowser() {
    let portal = M305C.cue(m305cWindow(url: "https://portal.acme-supplies.com/orders?id=abc", body: "Orders"))
    #expect(portal == AppCue(appName: "Browser", appBundleID: "recording.browser", host: "portal.acme-supplies.com",
                             ruleID: "browser"))
    #expect(AppCues.browser.appName == "Browser")
    #expect(AppCues.browser.appBundleID == "recording.browser")
    let other = M305C.cue(m305cWindow(url: "www.example.org", body: "Welcome"))
    #expect(other?.host == "www.example.org")
    #expect(other?.appBundleID == "recording.browser")
  }

  @Test("CUES: known window titles name the app when no host is shown (Gmail, QuickBooks, HubSpot, Slack, Excel, Google Sheets)")
  func windowTitlesNameTheApp() {
    let cases: [(String, String, String)] = [
      ("Inbox (3) - Gmail", "Gmail", "web.gmail"),
      ("Invoices | QuickBooks", "QuickBooks", "web.quickbooks"),
      ("quickbooks online", "QuickBooks", "web.quickbooks"),
      ("Contacts | HubSpot", "HubSpot", "web.hubspot"),
      ("general (Channel) - Acme - Slack", "Slack", "com.tinyspeck.slackmacgap"),
      ("Q3 invoices.xlsx - Excel", "Microsoft Excel", "com.microsoft.Excel"),
      ("Vendor list - Google Sheets", "Google Sheets", "web.google-sheets"),
    ]
    for (title, name, bundle) in cases {
      let cue = M305C.cue(m305cWindow(tab: title, body: "Totals"))
      #expect(cue?.appName == name, "\(title)")
      #expect(cue?.appBundleID == bundle, "\(title)")
      #expect(cue?.host == nil, "\(title)")
    }
    // A title is a whole word: "Slacker" and "Gmailbox" are not apps.
    #expect(M305C.cue(m305cWindow(tab: "Slacker news", body: "x")) == nil)
    #expect(M305C.cue(m305cWindow(tab: "Gmailbox archive", body: "x")) == nil)
  }

  @Test("CUES: a host wins over a title; among titles the topmost line wins, then the leftmost")
  func hostBeforeTitleTopmostFirst() {
    let both = [m305cLine("Contacts | HubSpot", y: 10), m305cLine("mail.google.com/mail/u/0", y: 50)]
    #expect(M305C.cue(both)?.appName == "Gmail")
    let stacked = [m305cLine("Invoices | QuickBooks", y: 30), m305cLine("Inbox - Gmail", y: 10, x: 700)]
    #expect(M305C.cue(stacked)?.appName == "Gmail")
    let row = [m305cLine("Inbox - Gmail", y: 10, x: 700), m305cLine("Contacts | HubSpot", y: 10, x: 100)]
    #expect(M305C.cue(row)?.appName == "HubSpot")
    // The first host in reading order is the URL bar; a later one (a bookmarks bar, a link) does not win.
    let hosts = [m305cLine("app.hubspot.com/contacts", y: 50), m305cLine("mail.google.com", y: 90)]
    #expect(M305C.cue(hosts)?.appName == "HubSpot")
  }

  @Test("CUES: only the window chrome band counts: a host or an app name in the body is not a cue")
  func onlyTheChromeBand() {
    #expect(AppCues.chromeBandHeight(frameHeight: 800) == 144)
    #expect(AppCues.chromeBandHeight(frameHeight: 400) == 96)
    #expect(AppCues.chromeBandHeight(frameHeight: 2000) == 360)
    #expect(M305C.cue(m305cWindow(body: "Ping me on Slack about mail.google.com")) == nil)
    #expect(M305C.cue([m305cLine("Inbox - Gmail", y: 150)]) == nil)
    #expect(M305C.cue([m305cLine("Inbox - Gmail", y: 140)])?.appName == "Gmail")
    #expect(M305C.cue([]) == nil)
  }

  @Test("CUES: email domains, file names, versions and addresses are not hosts")
  func notHosts() {
    for text in ["billing@acme-supplies.com", "Q3 report.pdf", "Invoices.xlsx", "notes.txt", "Version 1.5.2",
                 "10.0.0.1", "Okafor_contract.pdf", "-bad-.example.com"] {
      #expect(M305C.cue([m305cLine(text, y: 50)]) == nil, "\(text)")
    }
    #expect(AppCues.urlHosts(in: "From billing@acme-supplies.com via https://Portal.Acme-Supplies.com/x?y=1").map(\.host)
            == ["portal.acme-supplies.com"])
    #expect(AppCues.urlHosts(in: "docs.google.com/spreadsheets/d/abc").first?.path == "/spreadsheets/d/abc")
  }

  @Test("CUES: a host the masker would change is dropped, and app names come from the table only")
  func maskedHostDroppedNamesFromTable() {
    // The fake masker turns digit runs into <num>: this host would change, so it is not a cue.
    #expect(M305C.cue([m305cLine("https://crm4411.example.com/people", y: 50)]) == nil)
    let lines = [m305cLine("Amara Okafor - Gmail", y: 10), m305cLine("https://crm4411.example.com/people", y: 50)]
    #expect(M305C.cue(lines) == AppCue(appName: "Gmail", appBundleID: "web.gmail", host: nil, ruleID: "gmail"))
    let frames: [[OCRLine]] = [
      lines,
      m305cWindow(tab: "Amara Okafor (DM) - Slack", url: "app.slack.com/client/T1/D2", body: "Hi Amara"),
      m305cWindow(tab: "Okafor invoices.xlsx - Excel", body: "Total"),
      m305cWindow(url: "okafor-consulting.example.com/team", body: "Team"),
    ]
    for frame in frames {
      guard let cue = M305C.cue(frame) else { continue }
      #expect(M305C.cueNames.contains(cue.appName), "\(cue.appName)")
      #expect(!cue.appName.contains("Okafor") && !cue.appBundleID.lowercased().contains("okafor"))
      if let host = cue.host { #expect(FakeMasker().mask(host) == host) }
    }
  }

  @Test("CUES: a frame with no host and no known title gives no cue, so the app stays Screen")
  func noCueIsNil() {
    #expect(M305C.cue(m305cWindow(tab: "Untitled 3", body: "Totals")) == nil)
    #expect(M305C.cue(m305cWindow(tab: "Quarterly plan", url: "Search or enter address", body: "x")) == nil)
  }
}
