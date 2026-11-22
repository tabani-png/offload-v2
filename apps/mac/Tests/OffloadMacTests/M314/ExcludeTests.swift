import Foundation
import Testing
@testable import OffloadMac
import OffloadContracts
import OffloadImport
import OffloadObserver

// One Never watch list for the onboarding screens, the menu bar, the running observer and the recordings import
// (SPEC: "Never watch, one list").

extension M314 {
  @Test("EXCLUDE: Never watch entries become the observer's rules, kind for kind")
  func rulesKindForKind() {
    let rules = ExclusionBridge.rules(from: [
      Exclusion(kind: .bundleID, value: "com.apple.MobileSMS"),
      Exclusion(kind: .host, value: "bank.example"),
      Exclusion(kind: .titleContains, value: "Private Browsing", source: .builtin),
    ])
    #expect(rules == [
      ExclusionRule(kind: .bundleID, value: "com.apple.MobileSMS"),
      ExclusionRule(kind: .host, value: "bank.example"),
      ExclusionRule(kind: .titleContains, value: "Private Browsing"),
    ])
    // The observer's own policy then skips those windows (its built-in list stays in front).
    let policy = ExclusionPolicy(rules: ExclusionPolicy.builtin.rules + rules)
    #expect(policy.evaluate(FocusSnapshot(bundleID: "com.apple.MobileSMS", appName: "Messages", windowTitle: "Chat")) != nil)
    #expect(policy.evaluate(FocusSnapshot(bundleID: "com.apple.Safari", appName: "Safari", windowTitle: "Home",
                                          url: "https://www.bank.example/login")) != nil)
    #expect(policy.evaluate(FocusSnapshot(bundleID: "com.apple.Safari", appName: "Safari", windowTitle: "Notes",
                                          url: "https://notbank.example/")) == nil)
  }

  @Test("EXCLUDE: the exclusions file is written when the list changes and not rewritten when it did not")
  @MainActor func fileFollowsTheList() throws {
    let home = M314Fixture.tempHome()
    let file = home.appendingPathComponent("exclusions.json")
    let store = NeverWatchStore()
    let sync = ExclusionsFile(file: file, source: store)
    #expect(try sync.sync())
    // A plain copy of the Never watch list: owner-only, like the sealed store's files (SECURITY_PRIVACY section 6).
    let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
    #expect(mode == 0o600)
    let first = try ExclusionsFile.read(file)
    #expect(first == ExclusionBridge.rules(from: store.currentExclusions()))
    #expect(!(try sync.sync()))

    store.add([Exclusion(kind: .bundleID, value: "net.whatsapp.WhatsApp")])
    #expect(try sync.sync())
    #expect(try ExclusionsFile.read(file).contains(ExclusionRule(kind: .bundleID, value: "net.whatsapp.WhatsApp")))
    // The observer's reloader reads the same file (built-ins first, then these).
    let reloader = ExclusionReloader(file: file, time: ManualTime(M314Fixture.t0))
    #expect(reloader.policy(now: M314Fixture.t0).rules.contains(ExclusionRule(kind: .bundleID, value: "net.whatsapp.WhatsApp")))

    store.remove(Exclusion(kind: .bundleID, value: "net.whatsapp.WhatsApp"))
    #expect(try sync.sync())
    #expect(!(try ExclusionsFile.read(file).contains(ExclusionRule(kind: .bundleID, value: "net.whatsapp.WhatsApp"))))
  }

  @Test("EXCLUDE: one Never watch list feeds the observer file and the recordings import")
  @MainActor func oneList() throws {
    let wiring = M314Wiring()
    let home = M314Fixture.tempHome()
    let c = M314App.composition(state: M314State.watchingLocally, home: home, wiring: wiring)
    defer { c.capture.stop() }
    #expect(wiring.recordingsBuilt == 1)
    #expect(wiring.neverWatch === c.neverWatch)
    #expect(c.app.neverWatch === c.neverWatch)
    #expect(c.app.onboarding.services.neverWatch === c.neverWatch)
    #expect((c.capture.neverWatch as AnyObject) === c.neverWatch)

    // "Don't watch" from the menu bar reaches both readers.
    c.neverWatch.add([Exclusion(kind: .host, value: "bank.example")])
    #expect(try c.capture.syncExclusions())
    let observerRules = try ExclusionsFile.read(c.capture.exclusionsFile)
    #expect(observerRules.contains(ExclusionRule(kind: .host, value: "bank.example")))
    let importRules = NeverWatchImportExclusions(source: try #require(wiring.neverWatch)).currentRules()
    #expect(importRules.contains { $0.kind == .host && $0.value == "bank.example" })
  }
}
