import Foundation

// App cues (slice m3-05c-import-signals): a recording without a macOS menu bar (a window recording, an export, a
// full-screen app) still shows its app in the window chrome: a URL bar with a host, or a window or tab title. This is a
// pure, table-driven read of that chrome, used by the ingestor only when `MenuBarApp` gives nothing. Names and bundle
// ids come only from the table; the only frame text a cue keeps is a host the masker leaves unchanged.
//
// The table is also packages/contracts/rules/app-cues.json (for the cloud, m5-01); the M305C TABLE test keeps the two
// equal. Change both together.

/// One app the chrome can show: its URL-bar host patterns (`host` or `host/path-prefix`; a pattern matches the host or
/// any subdomain, and the path prefix is for matching only) and its window titles (whole words, any case).
public struct AppCueRule: Equatable, Sendable {
  public let id: String
  public let appName: String
  public let appBundleID: String
  public let hosts: [String]
  public let titles: [String]

  public init(id: String, appName: String, appBundleID: String, hosts: [String], titles: [String]) {
    self.id = id
    self.appName = appName
    self.appBundleID = appBundleID
    self.hosts = hosts
    self.titles = titles
  }
}

/// What a frame's chrome says about its app. `host` is set only for a URL-bar cue.
public struct AppCue: Equatable, Sendable {
  public var appName: String
  public var appBundleID: String
  public var host: String?
  /// The table rule's id, or `browser` for a host the table does not know.
  public var ruleID: String

  public init(appName: String, appBundleID: String, host: String?, ruleID: String) {
    self.appName = appName
    self.appBundleID = appBundleID
    self.host = host
    self.ruleID = ruleID
  }
}

public enum AppCues {
  public static let tableVersion = 1
  /// The window chrome band: the top `chromeFraction` of the frame, at least `chromeMinPixels`. It holds a title bar,
  /// a tab strip and a toolbar with the URL bar on a 1280 px frame.
  public static let chromeFraction = 0.18
  public static let chromeMinPixels: Double = 96
  /// The app of a URL-bar host the table does not know: different sites stay apart by their host.
  public static let browser = AppCueRule(id: "browser", appName: "Browser", appBundleID: "recording.browser",
                                         hosts: [], titles: [])
  /// File extensions that are never a top-level domain here ("Invoices.xlsx" in a title bar is not a host).
  public static let notTLDs: [String] = [
    "pdf", "xlsx", "xls", "xlsm", "csv", "doc", "docx", "ppt", "pptx", "key", "numbers", "pages", "txt", "rtf", "md",
    "json", "xml", "yaml", "yml", "log", "png", "jpg", "jpeg", "gif", "heic", "webp", "svg", "tif", "tiff", "mov",
    "zip", "dmg", "pkg", "eml", "msg", "ics", "vcf", "sql", "py", "js", "ts", "swift", "sh", "html", "htm", "css",
  ]

  /// The table, in the JSON file's order (the order breaks ties).
  public static let rules: [AppCueRule] = [
    AppCueRule(id: "gmail", appName: "Gmail", appBundleID: "web.gmail",
               hosts: ["mail.google.com"], titles: ["Gmail"]),
    AppCueRule(id: "google-sheets", appName: "Google Sheets", appBundleID: "web.google-sheets",
               hosts: ["docs.google.com/spreadsheets"], titles: ["Google Sheets"]),
    AppCueRule(id: "google-docs", appName: "Google Docs", appBundleID: "web.google-docs",
               hosts: ["docs.google.com/document"], titles: ["Google Docs"]),
    AppCueRule(id: "google-slides", appName: "Google Slides", appBundleID: "web.google-slides",
               hosts: ["docs.google.com/presentation"], titles: ["Google Slides"]),
    AppCueRule(id: "google-drive", appName: "Google Drive", appBundleID: "web.google-drive",
               hosts: ["drive.google.com"], titles: ["Google Drive"]),
    AppCueRule(id: "google-calendar", appName: "Google Calendar", appBundleID: "web.google-calendar",
               hosts: ["calendar.google.com"], titles: ["Google Calendar"]),
    AppCueRule(id: "quickbooks", appName: "QuickBooks", appBundleID: "web.quickbooks",
               hosts: ["qbo.intuit.com", "quickbooks.intuit.com"], titles: ["QuickBooks"]),
    AppCueRule(id: "xero", appName: "Xero", appBundleID: "web.xero",
               hosts: ["go.xero.com"], titles: ["Xero"]),
    AppCueRule(id: "hubspot", appName: "HubSpot", appBundleID: "web.hubspot",
               hosts: ["app.hubspot.com"], titles: ["HubSpot"]),
    AppCueRule(id: "salesforce", appName: "Salesforce", appBundleID: "web.salesforce",
               hosts: ["lightning.force.com", "my.salesforce.com"], titles: ["Salesforce"]),
    AppCueRule(id: "slack", appName: "Slack", appBundleID: "com.tinyspeck.slackmacgap",
               hosts: ["app.slack.com"], titles: ["Slack"]),
    AppCueRule(id: "excel", appName: "Microsoft Excel", appBundleID: "com.microsoft.Excel",
               hosts: ["excel.cloud.microsoft", "excel.office.com"], titles: ["Microsoft Excel", "Excel"]),
    AppCueRule(id: "outlook", appName: "Microsoft Outlook", appBundleID: "com.microsoft.Outlook",
               hosts: ["outlook.office.com", "outlook.live.com", "outlook.cloud.microsoft"], titles: ["Microsoft Outlook", "Outlook"]),
    AppCueRule(id: "notion", appName: "Notion", appBundleID: "notion.id",
               hosts: ["notion.so"], titles: ["Notion"]),
    AppCueRule(id: "airtable", appName: "Airtable", appBundleID: "web.airtable",
               hosts: ["airtable.com"], titles: ["Airtable"]),
    AppCueRule(id: "stripe", appName: "Stripe", appBundleID: "web.stripe",
               hosts: ["dashboard.stripe.com"], titles: ["Stripe"]),
    AppCueRule(id: "shopify", appName: "Shopify", appBundleID: "web.shopify",
               hosts: ["admin.shopify.com"], titles: ["Shopify"]),
    AppCueRule(id: "zendesk", appName: "Zendesk", appBundleID: "web.zendesk",
               hosts: ["zendesk.com"], titles: ["Zendesk"]),
    AppCueRule(id: "jira", appName: "Jira", appBundleID: "web.jira",
               hosts: ["atlassian.net/jira", "atlassian.net/browse"], titles: ["Jira"]),
    AppCueRule(id: "confluence", appName: "Confluence", appBundleID: "web.confluence",
               hosts: ["atlassian.net/wiki"], titles: ["Confluence"]),
    AppCueRule(id: "asana", appName: "Asana", appBundleID: "web.asana",
               hosts: ["app.asana.com"], titles: ["Asana"]),
    AppCueRule(id: "trello", appName: "Trello", appBundleID: "web.trello",
               hosts: ["trello.com"], titles: ["Trello"]),
    AppCueRule(id: "linear", appName: "Linear", appBundleID: "com.linear",
               hosts: ["linear.app"], titles: []),
    AppCueRule(id: "docusign", appName: "DocuSign", appBundleID: "web.docusign",
               hosts: ["app.docusign.com"], titles: ["DocuSign"]),
    AppCueRule(id: "gusto", appName: "Gusto", appBundleID: "web.gusto",
               hosts: ["app.gusto.com"], titles: ["Gusto"]),
  ]

  public static func chromeBandHeight(frameHeight: Int) -> Double {
    max(chromeMinPixels, Double(frameHeight) * chromeFraction)
  }

  /// The app cue of one frame, or nil. Only lines whose box starts inside the chrome band count, read top to bottom,
  /// then left to right. A URL-bar host wins (the first one the masker leaves unchanged: the table's app with the
  /// longest matching pattern, else `browser`); else a table title on the topmost line that has one; else nil.
  public static func classify(_ lines: [OCRLine], frameHeight: Int, masker: any ImportTextMasker) -> AppCue? {
    let band = chromeBandHeight(frameHeight: frameHeight)
    let chrome = lines.filter { $0.box.y < band }.sorted { ($0.box.y, $0.box.x) < ($1.box.y, $1.box.x) }
    for line in chrome {
      for found in urlHosts(in: line.text) where masker.mask(found.host) == found.host {
        let rule = self.rule(forHost: found.host, path: found.path) ?? browser
        return AppCue(appName: rule.appName, appBundleID: rule.appBundleID, host: found.host, ruleID: rule.id)
      }
    }
    for line in chrome {
      if let rule = titleRule(in: line.text) {
        return AppCue(appName: rule.appName, appBundleID: rule.appBundleID, host: nil, ruleID: rule.id)
      }
    }
    return nil
  }

  /// A host read off a line, lowercased, and the path after it (for matching only; never kept).
  public struct URLHost: Equatable, Sendable {
    public var host: String
    public var path: String
  }

  /// URL-bar hosts in one line: `https://mail.google.com/mail/u/0`, `qbo.intuit.com/app`, `www.example.org`. A token
  /// with an `@` (an email address) is never a host; the last label must be letters only and not a file extension
  /// (`notTLDs`), so file names, versions and IP addresses are not hosts.
  public static func urlHosts(in line: String) -> [URLHost] {
    var out: [URLHost] = []
    for raw in line.split(whereSeparator: { $0.isWhitespace }) {
      guard !raw.contains("@") else { continue }
      var token = raw.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "()[]<>{}\"'.,;:!|"))
      if let r = token.range(of: "://") { token = String(token[r.upperBound...]) }
      var hostPart = token
      var path = ""
      if let cut = token.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) {
        hostPart = String(token[..<cut])
        if token[cut] == "/" {
          let rest = token[cut...]
          path = String(rest.prefix { $0 != "?" && $0 != "#" })
        }
      }
      if let colon = hostPart.firstIndex(of: ":") { hostPart = String(hostPart[..<colon]) }
      while hostPart.hasSuffix(".") { hostPart.removeLast() }
      guard isHost(hostPart) else { continue }
      out.append(URLHost(host: hostPart, path: path))
    }
    return out
  }

  static func isHost(_ text: String) -> Bool {
    let labels = text.split(separator: ".", omittingEmptySubsequences: false)
    guard labels.count >= 2, text.count <= 253 else { return false }
    for label in labels {
      guard let first = label.first, let last = label.last, label.count <= 63,
            isLowerAlnum(first), isLowerAlnum(last),
            label.allSatisfy({ isLowerAlnum($0) || $0 == "-" }) else { return false }
    }
    guard let tld = labels.last, tld.count >= 2, tld.allSatisfy({ $0 >= "a" && $0 <= "z" }) else { return false }
    return !notTLDs.contains(String(tld))
  }

  private static func isLowerAlnum(_ c: Character) -> Bool {
    (c >= "a" && c <= "z") || (c >= "0" && c <= "9")
  }

  /// The table rule with the longest host pattern matching `host` (or a subdomain) and `path`; ties keep table order.
  static func rule(forHost host: String, path: String) -> AppCueRule? {
    var best: (rule: AppCueRule, length: Int)?
    for rule in rules {
      for pattern in rule.hosts {
        let parts = pattern.split(separator: "/", maxSplits: 1)
        guard let base = parts.first.map(String.init), host == base || host.hasSuffix("." + base) else { continue }
        if parts.count > 1 {
          let prefix = "/" + parts[1]
          guard path == prefix || path.hasPrefix(prefix + "/") else { continue }
        }
        if let b = best, pattern.count <= b.length { continue }
        best = (rule, pattern.count)
      }
    }
    return best?.rule
  }

  /// The table rule whose title is on the line as a whole word (any case): the longest title; ties keep table order.
  static func titleRule(in line: String) -> AppCueRule? {
    let text = line.lowercased()
    var best: (rule: AppCueRule, length: Int)?
    for rule in rules {
      for title in rule.titles where containsWord(text, title.lowercased()) {
        if let b = best, title.count <= b.length { continue }
        best = (rule, title.count)
      }
    }
    return best?.rule
  }

  /// True when `word` is in `text` with no letter or digit right before or after it.
  static func containsWord(_ text: String, _ word: String) -> Bool {
    guard !word.isEmpty else { return false }
    var from = text.startIndex
    while from < text.endIndex, let r = text.range(of: word, range: from..<text.endIndex) {
      let before = r.lowerBound == text.startIndex || !isWordCharacter(text[text.index(before: r.lowerBound)])
      let after = r.upperBound == text.endIndex || !isWordCharacter(text[r.upperBound])
      if before && after { return true }
      from = text.index(after: r.lowerBound)
    }
    return false
  }

  private static func isWordCharacter(_ c: Character) -> Bool { c.isLetter || c.isNumber }
}
