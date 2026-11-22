import Foundation
import Testing

@testable import OffloadContracts
@testable import OffloadObserver

extension M302 {
    @Test("EXCLUDE: a password manager window yields the app name only")
    func passwordManagerYieldsAppNameOnly() async throws {
        let rig = Rig()
        rig.workspace.snapshot = FocusSnapshot(bundleID: "com.1password.1password", appName: "1Password", windowTitle: "Vault - Personal - Bank login", url: nil)
        rig.ax.text = String(repeating: "secret vault content ", count: 20)
        rig.ocr.text = "more secret content"
        await rig.tick()
        await rig.tick(31)
        let items = try rig.observed()
        let f = focuses(items)
        #expect(f.count == 1)
        #expect(f.first?.appName == "1Password")
        #expect(f.first?.appBundleId == "com.1password.1password")
        #expect(f.first?.title == nil && f.first?.host == nil && f.first?.doc == nil)
        #expect(snapshots(items).isEmpty)
        #expect(rig.ax.calls == 0 && rig.ocr.calls == 0)
    }

    @Test("EXCLUDE: a private browsing title marker drops title and host")
    func privateBrowsingDropsTitleAndHost() async throws {
        let rig = Rig()
        rig.workspace.snapshot = FocusSnapshot(
            bundleID: "com.google.Chrome", appName: "Google Chrome", windowTitle: "Quarterly numbers - Incognito",
            url: "https://docs.google.com/spreadsheets/d/abc/edit")
        rig.ax.text = String(repeating: "private numbers ", count: 30)
        await rig.tick()
        let items = try rig.observed()
        let f = focuses(items)
        #expect(f.count == 1)
        #expect(f.first?.title == nil && f.first?.host == nil && f.first?.doc == nil)
        #expect(snapshots(items).isEmpty)
        #expect(rig.ax.calls == 0)
        // The same rule sees a banking host, whatever the window title says.
        let policy = ExclusionPolicy.builtin
        #expect(policy.evaluate(FocusSnapshot(bundleID: "com.apple.Safari", appName: "Safari", windowTitle: "Accounts", url: "https://www.chase.com/personal")) != nil)
        #expect(policy.evaluate(FocusSnapshot(bundleID: "com.apple.Safari", appName: "Safari", windowTitle: "Accounts", url: "https://notchase.com/")) == nil)
    }

    @Test("EXCLUDE: a user exclusion added at runtime applies within one 2 s reload")
    func userExclusionAppliesWithinTwoSeconds() async throws {
        let rig = Rig()
        rig.workspace.snapshot = FocusSnapshot(
            bundleID: "com.apple.Safari", appName: "Safari", windowTitle: "Payroll run", url: "https://payroll.internal.example/run/9")
        rig.ax.text = String(repeating: "payroll rows ", count: 30)
        await rig.tick()
        #expect(snapshots(try rig.observed()).count == 1)
        #expect(focuses(try rig.observed()).first?.host == "payroll.internal.example")

        // The member adds "Never watch payroll.internal.example": the app writes exclusions.json.
        try Data(#"[{"kind":"host","value":"payroll.internal.example"}]"#.utf8).write(to: rig.exclusionsFile)
        rig.ax.text += "more rows added later"
        await rig.tick(2.5)
        let items = try rig.observed()
        let last = try #require(focuses(items).last)
        #expect(last.title == nil && last.host == nil)
        #expect(last.appName == "Safari")
        await rig.tick(31)
        #expect(snapshots(try rig.observed()).count == 1, "no text after the exclusion applied")
    }
}
