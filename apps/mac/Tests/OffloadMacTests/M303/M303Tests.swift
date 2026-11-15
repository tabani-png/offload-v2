// m3-03-mac-signing-sparkle: Swift part (tag SPARKLE). Contract: slices/m3-03-mac-signing-sparkle/SPEC.md.
// The update logic is tested without a running Sparkle updater: UpdateLifecycle, UpdateChannels and UpdateFeedConfig
// hold the decisions, UpdaterController and UpdaterDelegate only forward to them.
import Foundation
import Testing
@testable import OffloadMac

/// Records capture calls and whether the pending relaunch check was already written when each call came.
@MainActor
private final class RecordingCapture: CaptureLifecycle {
    let settings: any SettingsStore
    private(set) var calls: [String] = []
    private(set) var flagWasSetAtPrepare: [Bool] = []

    init(settings: any SettingsStore) { self.settings = settings }

    func start() { calls.append("start") }

    func prepareForUpdate() {
        calls.append("prepareForUpdate")
        flagWasSetAtPrepare.append(settings.bool(forKey: UpdateLifecycle.pendingRelaunchCheckKey))
    }
}

/// Counts checks per permission and answers from a fixed table.
@MainActor
private final class CountingPermissionSource: PermissionSource {
    var granted: [Permission: Bool]
    private(set) var checks: [Permission: Int] = [:]

    init(granted: [Permission: Bool]) { self.granted = granted }

    func isGranted(_ permission: Permission) -> Bool {
        checks[permission, default: 0] += 1
        return granted[permission] ?? false
    }
}

/// A fresh defaults domain per test, removed at the end.
private func freshDefaults() throws -> (UserDefaults, String) {
    let name = "ai.offload.mac.tests.m303.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: name))
    return (defaults, name)
}

/// A complete, valid set of the four Sparkle keys (a function, not a global: [String: Any] is not Sendable).
private func validFeed() -> [String: Any] {
    [
        "SUFeedURL": "https://downloads.example.test/appcast.xml",
        "SUPublicEDKey": "AAAAC3NzaC1lZDI1NTE5AAAAIExamplePublicKeyOnlyForTests00000000",
        "SURequireSignedFeed": true,
        "SUVerifyUpdateBeforeExtraction": true,
    ]
}

@Suite struct M303 {
    @MainActor
    @Test("SPARKLE: the updater flushes the upload queue and stops capture before it installs")
    func prepareBeforeInstall() throws {
        let (defaults, name) = try freshDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let capture = RecordingCapture(settings: defaults)
        let permissions = CountingPermissionSource(granted: [.accessibility: true, .screenRecording: true])
        let lifecycle = UpdateLifecycle(capture: capture, permissions: permissions, settings: defaults)

        #expect(capture.calls.isEmpty)
        lifecycle.willInstallUpdate()

        #expect(capture.calls == ["prepareForUpdate"])
        #expect(capture.flagWasSetAtPrepare == [false])
        #expect(defaults.bool(forKey: UpdateLifecycle.pendingRelaunchCheckKey))
        #expect(permissions.checks.isEmpty)
    }

    @MainActor
    @Test("SPARKLE: beta items are offered only when Get early builds is on")
    func betaOnlyWithEarlyBuilds() throws {
        let (defaults, name) = try freshDefaults()
        defer { defaults.removePersistentDomain(forName: name) }

        #expect(UpdateChannels.allowedChannels(settings: defaults).isEmpty)
        defaults.set(false, forKey: UpdateChannels.getEarlyBuildsKey)
        #expect(UpdateChannels.allowedChannels(settings: defaults).isEmpty)
        defaults.set(true, forKey: UpdateChannels.getEarlyBuildsKey)
        #expect(UpdateChannels.allowedChannels(settings: defaults) == ["beta"])
        defaults.removeObject(forKey: UpdateChannels.getEarlyBuildsKey)
        #expect(UpdateChannels.allowedChannels(settings: defaults).isEmpty)

        #expect(UpdateChannels.allowedChannels(getEarlyBuilds: true) == ["beta"])
        #expect(UpdateChannels.allowedChannels(getEarlyBuilds: false).isEmpty)
    }

    @Test("SPARKLE: an Info.plist without a signed https feed turns updates off")
    func feedNeedsSignedHttps() {
        var httpFeed = validFeed()
        httpFeed["SUFeedURL"] = "http://downloads.example.test/appcast.xml"
        var noHost = validFeed()
        noHost["SUFeedURL"] = "https:///appcast.xml"
        var noKey = validFeed()
        noKey.removeValue(forKey: "SUPublicEDKey")
        var emptyKey = validFeed()
        emptyKey["SUPublicEDKey"] = ""
        var unsignedFeed = validFeed()
        unsignedFeed["SURequireSignedFeed"] = false
        var noVerify = validFeed()
        noVerify.removeValue(forKey: "SUVerifyUpdateBeforeExtraction")

        let offCases: [[String: Any]] = [[:], httpFeed, noHost, noKey, emptyKey, unsignedFeed, noVerify]
        for info in offCases {
            let config = UpdateFeedConfig(info: info)
            #expect(config.isEnabled == false)
            #expect(config.statusLine == "updates off in this build")
        }

        let on = UpdateFeedConfig(info: validFeed())
        #expect(on.isEnabled)
        #expect(on.statusLine != "updates off in this build")

        // The bundling script writes plist booleans; string and number forms read the same way.
        var stringForms = validFeed()
        stringForms["SURequireSignedFeed"] = "YES"
        stringForms["SUVerifyUpdateBeforeExtraction"] = NSNumber(value: true)
        #expect(UpdateFeedConfig(info: stringForms).isEnabled)
    }

    @MainActor
    @Test("SPARKLE: after an update relaunch both permissions are checked again")
    func relaunchChecksBothPermissions() throws {
        let (defaults, name) = try freshDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let capture = RecordingCapture(settings: defaults)
        let permissions = CountingPermissionSource(granted: [.accessibility: true, .screenRecording: false])
        let lifecycle = UpdateLifecycle(capture: capture, permissions: permissions, settings: defaults)

        // An ordinary launch checks nothing here.
        #expect(lifecycle.didLaunch().isEmpty)
        #expect(permissions.checks.isEmpty)

        lifecycle.willInstallUpdate()
        let missing = lifecycle.didLaunch()

        #expect(permissions.checks[.accessibility] == 1)
        #expect(permissions.checks[.screenRecording] == 1)
        #expect(missing == [.screenRecording])
        #expect(defaults.bool(forKey: UpdateLifecycle.pendingRelaunchCheckKey) == false)

        // The flag is cleared, so the next launch checks nothing again.
        #expect(lifecycle.didLaunch().isEmpty)
        #expect(permissions.checks[.accessibility] == 1)
        #expect(permissions.checks[.screenRecording] == 1)
    }

    @MainActor
    @Test("SPARKLE: the self-check passes against a fake permission source with a temp HOME")
    func selfCheckWithTempHome() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("offload-m303-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        var lines: [String] = []
        let code = SelfCheck.run(
            environment: ["HOME": home.path],
            info: [:],
            permissions: FakePermissionSource(),
            capture: CaptureNotStarted(),
            write: { lines.append($0) }
        )
        #expect(code == 0)
        #expect(lines.contains("self-check: updates off in this build"))
        #expect(lines.last == "self-check: ok")
        #expect(try FileManager.default.contentsOfDirectory(atPath: home.path).isEmpty)

        var failed: [String] = []
        let missingHome = SelfCheck.run(
            environment: [:],
            info: [:],
            permissions: FakePermissionSource(),
            capture: CaptureNotStarted(),
            write: { failed.append($0) }
        )
        #expect(missingHome == 1)
        #expect(failed.last?.hasPrefix("self-check: failed (") == true)
    }
}
