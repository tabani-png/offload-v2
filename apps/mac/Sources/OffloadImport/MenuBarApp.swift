import Foundation

// Ported from PR #44 (engine/Sources/OffloadCore/Recordings/MenuBarApp.swift). A recording has no Accessibility tree,
// so the app in front is read off the menu bar: the words left of the first menu title ("Safari File Edit View" ->
// "Safari"). Unknown apps get a stable `recording.<slug>` id so they are still kept apart.

public enum MenuBarApp {
  /// Menu titles that follow the app menu in common apps.
  static let menus: Set<String> = ["File", "Edit", "View", "Go", "Window", "Help", "History", "Bookmarks", "Format",
                                   "Insert", "Table", "Shell", "Mailbox", "Message", "Conversation", "Navigate",
                                   "Selection", "Run", "Terminal", "Profiles", "Tab", "Arrange", "Share", "Data",
                                   "Tools", "Debug", "Product", "Editor", "Find", "Song", "Controls", "Account"]

  /// The menu bar band: the top 4 % of the frame, at least 24 px.
  public static func bandHeight(frameHeight: Int) -> Double {
    max(24, Double(frameHeight) * 0.04)
  }

  public static func isInBand(_ line: OCRLine, frameHeight: Int) -> Bool {
    line.box.y < bandHeight(frameHeight: frameHeight)
  }

  /// The app name the menu bar shows, or nil when the top band is not a menu bar. A menu bar is the app name (at
  /// most 3 words) followed by two menu titles; anything else in the band (a window-only recording, a hidden menu
  /// bar) is window content, which must never become an app name (review 1: it would leave unmasked).
  public static func name(from lines: [OCRLine], frameHeight: Int) -> String? {
    var bandWords: [OCRWord] = []
    for line in lines where isInBand(line, frameHeight: frameHeight) { bandWords.append(contentsOf: line.words) }
    bandWords.sort { $0.box.x < $1.box.x }
    // Drops the Apple logo and other symbols.
    let words = bandWords.map(\.text).filter(hasAlphanumeric)
    guard words.count >= 3,
          let i = words.indices.dropFirst().first(where: { menus.contains(words[$0]) }), i <= 3,
          i + 1 < words.count, menus.contains(words[i + 1]) else { return nil }
    return words[..<i].joined(separator: " ")
  }

  private static func hasAlphanumeric(_ text: String) -> Bool {
    text.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) }
  }

  /// App names (lowercased) to bundle ids, from PR #44 and s34 `folder.ts`.
  static let known: [String: String] = [
    "safari": "com.apple.Safari", "google chrome": "com.google.Chrome", "chrome": "com.google.Chrome",
    "arc": "company.thebrowser.Browser", "firefox": "org.mozilla.firefox", "microsoft edge": "com.microsoft.edgemac",
    "brave browser": "com.brave.Browser", "mail": "com.apple.mail", "outlook": "com.microsoft.Outlook",
    "microsoft outlook": "com.microsoft.Outlook", "slack": "com.tinyspeck.slackmacgap", "messages": "com.apple.MobileSMS",
    "numbers": "com.apple.iWork.Numbers", "pages": "com.apple.iWork.Pages", "keynote": "com.apple.iWork.Keynote",
    "microsoft excel": "com.microsoft.Excel", "excel": "com.microsoft.Excel", "microsoft word": "com.microsoft.Word",
    "word": "com.microsoft.Word", "microsoft powerpoint": "com.microsoft.Powerpoint", "microsoft teams": "com.microsoft.teams2",
    "notes": "com.apple.Notes", "finder": "com.apple.finder", "xcode": "com.apple.dt.Xcode",
    "code": "com.microsoft.VSCode", "visual studio code": "com.microsoft.VSCode", "cursor": "com.todesktop.230313mzl4w4u92",
    "terminal": "com.apple.Terminal", "iterm2": "com.googlecode.iterm2", "calendar": "com.apple.iCal",
    "zoom.us": "us.zoom.xos", "zoom": "us.zoom.xos", "notion": "notion.id", "figma": "com.figma.Desktop",
    "preview": "com.apple.Preview", "linear": "com.linear", "discord": "com.hnc.Discord", "spotify": "com.spotify.client",
    "whatsapp": "net.whatsapp.WhatsApp", "telegram": "ru.keepcoder.Telegram", "claude": "com.anthropic.claudefordesktop",
    "chatgpt": "com.openai.chat", "1password": "com.1password.1password", "1password 7": "com.agilebits.onepassword7",
    "bitwarden": "com.bitwarden.desktop", "keychain access": "com.apple.keychainaccess", "passwords": "com.apple.Passwords",
  ]

  /// The bundle id for an app name, or `recording.<slug>`; `recording.unknown` when there is no name.
  public static func bundleID(for name: String?) -> String {
    guard let name, !name.isEmpty else { return "recording.unknown" }
    if let id = known[name.lowercased()] { return id }
    var dashed = ""
    for scalar in name.lowercased().unicodeScalars {
      if CharacterSet.alphanumerics.contains(scalar) { dashed.unicodeScalars.append(scalar) } else { dashed += "-" }
    }
    let slug = dashed.split(separator: "-").joined(separator: "-")
    return "recording." + (slug.isEmpty ? "unknown" : slug)
  }
}
