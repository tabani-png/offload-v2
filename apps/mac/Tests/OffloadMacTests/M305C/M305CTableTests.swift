import Foundation
import Testing
@testable import OffloadImport

// The Swift cue table and the JSON table the cloud reads (packages/contracts/rules/app-cues.json) are the same rules.
extension M305C {
  // MARK: TABLE

  @Test("TABLE: the Swift table is the JSON table in packages/contracts/rules/app-cues.json")
  func swiftTableIsTheJSONTable() throws {
    let data = try Data(contentsOf: M305CRepo.cueTable)
    let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(json["version"] as? Int == AppCues.tableVersion)
    let band = try #require(json["chrome_band"] as? [String: Any])
    #expect((band["fraction"] as? NSNumber)?.doubleValue == AppCues.chromeFraction)
    #expect((band["min_px"] as? NSNumber)?.doubleValue == AppCues.chromeMinPixels)
    let browser = try #require(json["browser"] as? [String: Any])
    #expect(browser["app_name"] as? String == AppCues.browser.appName)
    #expect(browser["app_bundle_id"] as? String == AppCues.browser.appBundleID)
    #expect(json["not_tlds"] as? [String] == AppCues.notTLDs)
    #expect(json["tlds"] as? [String] == AppCues.tlds)
    let apps = try #require(json["apps"] as? [[String: Any]])
    #expect(apps.count == AppCues.rules.count)
    for (row, rule) in zip(apps, AppCues.rules) {
      #expect(row["id"] as? String == rule.id)
      #expect(row["app_name"] as? String == rule.appName, "\(rule.id)")
      #expect(row["app_bundle_id"] as? String == rule.appBundleID, "\(rule.id)")
      #expect(row["hosts"] as? [String] == rule.hosts, "\(rule.id)")
      #expect(row["titles"] as? [String] == rule.titles, "\(rule.id)")
    }
  }

  @Test("TABLE: every rule is well formed: unique ids and titles, lowercase bare hosts with an optional path prefix")
  func rulesAreWellFormed() {
    let ids = AppCues.rules.map(\.id)
    #expect(Set(ids).count == ids.count)
    let titles = AppCues.rules.flatMap(\.titles).map { $0.lowercased() }
    #expect(Set(titles).count == titles.count)
    // The six window titles the brief names are in the table.
    for title in ["Gmail", "QuickBooks", "HubSpot", "Slack", "Excel", "Google Sheets"] {
      #expect(AppCues.rules.contains { $0.titles.contains(title) }, "\(title)")
    }
    for rule in AppCues.rules {
      #expect(!rule.hosts.isEmpty || !rule.titles.isEmpty, "\(rule.id)")
      #expect(!rule.appName.isEmpty && rule.appName.count <= 256)
      #expect(!rule.appBundleID.isEmpty && rule.appBundleID.count <= 255)
      for pattern in rule.hosts {
        let host = pattern.split(separator: "/", maxSplits: 1).first.map(String.init) ?? ""
        #expect(pattern == pattern.lowercased(), "\(pattern)")
        #expect(!pattern.contains("?") && !pattern.contains("#") && !pattern.contains(":"), "\(pattern)")
        // A table host is itself a host the classifier would read.
        #expect(AppCues.urlHosts(in: pattern).first?.host == host, "\(pattern)")
      }
    }
  }
}
