import CryptoKit
import Foundation
import Testing

@testable import OffloadContracts
@testable import OffloadObserver
@testable import OffloadStore

extension M302 {
    @Test("STORE: a day file decrypts only with its day key")
    func dayFileDecryptsOnlyWithItsKey() throws {
        let home = TestHome()
        let store = home.dayStore()
        let ids = ULIDGenerator()
        let at = t0.addingTimeInterval(60)
        let o = Observation.focus(ObservationFocus(
            id: ids.next(millis: Int64(at.timeIntervalSince1970 * 1000)), ts: Timestamp.format(at),
            appBundleId: "com.apple.mail", appName: "Mail", title: "Quarterly close"))
        try store.append(o)
        let day = home.days.day(of: at)
        let file = try Data(contentsOf: home.layout.dayFile(day))
        #expect(file.range(of: Data("Quarterly close".utf8)) == nil)
        let line = try #require(file.split(separator: UInt8(ascii: "\n")).first)
        let sealed = try #require(Data(base64Encoded: Data(line)))
        let right = try home.keys.dayKey(domain: .days, day: day, create: false)
        #expect(StoreCrypto.open(sealed, key: right) != nil)
        #expect(StoreCrypto.open(sealed, key: SymmetricKey(size: .bits256)) == nil)
        // Another day's key does not open it either, and the store reads it back with the right one.
        let other = try home.keys.dayKey(domain: .days, day: "2025-12-31", create: true)
        #expect(StoreCrypto.open(sealed, key: other) == nil)
        #expect(try store.read(day: day) == [o])
        // Day keys live wrapped on disk: the key file is not the raw key.
        let keyFile = try Data(contentsOf: home.layout.keyFile(domain: .days, day: day))
        #expect(keyFile.count != 32 && keyFile.range(of: right.withUnsafeBytes { Data($0) }) == nil)
        // A purged key means the day is unreadable.
        try FileManager.default.removeItem(at: home.layout.keyFile(domain: .days, day: day))
        home.keys.forget()
        #expect(throws: StoreError.self) { try store.read(day: day) }
    }

    @Test("STORE: purge removes days older than 7 and logs them")
    func purgeRemovesOldDays() throws {
        let home = TestHome()
        let store = home.dayStore()
        let ids = ULIDGenerator()
        let now = t0.addingTimeInterval(20 * 86_400)
        var written: [String] = []
        for age in [9, 8, 7, 3, 0] {
            let at = now.addingTimeInterval(-Double(age) * 86_400)
            try store.append(.focus(ObservationFocus(
                id: ids.next(millis: Int64(at.timeIntervalSince1970 * 1000)), ts: Timestamp.format(at),
                appBundleId: "com.apple.mail", appName: "Mail")))
            written.append(home.days.day(of: at))
        }
        let retention = Retention(layout: home.layout, days: home.days)
        let records = try retention.purge(now: now)
        let purged = records.map { $0.day }.sorted()
        #expect(purged == [written[0], written[1]].sorted())
        #expect(retention.storedDays(domain: .days) == [written[2], written[3], written[4]].sorted())
        for day in [written[0], written[1]] {
            #expect(!FileManager.default.fileExists(atPath: home.layout.dayFile(day).path))
            #expect(!FileManager.default.fileExists(atPath: home.layout.keyFile(domain: .days, day: day).path))
        }
        // One line per purged day in the purge log: ids and counts only, no content.
        let log = try String(contentsOf: home.layout.purgeLog, encoding: .utf8)
        let lines = log.split(separator: "\n")
        #expect(lines.count == 2)
        #expect(log.contains(written[0]) && log.contains(written[1]))
        #expect(!log.contains("Mail"))
        // Nothing left to purge the second time.
        #expect(try retention.purge(now: now).isEmpty)
    }

    @Test("STORE: secure input pauses text capture")
    func secureInputPausesTextCapture() async throws {
        let rig = Rig()
        rig.workspace.snapshot = FocusSnapshot(
            bundleID: "com.apple.Safari", appName: "Safari", windowTitle: "Sign in", url: "https://login.example.com/",
            secureInputActive: true)
        rig.ax.text = String(repeating: "visible page text ", count: 30)
        rig.ocr.text = "ocr page text"
        await rig.tick()
        await rig.tick(31)
        #expect(snapshots(try rig.observed()).isEmpty)
        #expect(rig.ax.calls == 0 && rig.ocr.calls == 0)
        // The password field lost focus: text capture resumes at once.
        rig.workspace.snapshot = FocusSnapshot(bundleID: "com.apple.Safari", appName: "Safari", windowTitle: "Sign in", url: "https://login.example.com/")
        await rig.tick()
        #expect(snapshots(try rig.observed()).count == 1)
    }

    @Test("STORE: screen lock writes pause with reason lock and nothing until resume")
    func screenLockPauses() async throws {
        let rig = Rig()
        rig.ax.text = String(repeating: "before the lock ", count: 20)
        await rig.tick()
        rig.pause.reason = .lock
        await rig.tick()
        rig.workspace.snapshot = FocusSnapshot(bundleID: "com.apple.Notes", appName: "Notes", windowTitle: "Draft", url: nil)
        rig.ax.text = String(repeating: "typed while locked ", count: 20)
        await rig.tick(31)
        await rig.tick(31)
        var items = try rig.observed()
        let p = pauses(items)
        #expect(p.count == 1 && p.first?.reason == .lock)
        let before = items.count
        #expect(kinds(items).last == "pause")
        rig.pause.reason = nil
        await rig.tick()
        items = try rig.observed()
        #expect(items.count > before)
        let r = resumes(items)
        #expect(r.count == 1 && r.first?.reason == .lock)
        // After the resume the current window is written again.
        #expect(focuses(items).last?.appName == "Notes")
        // Sleep is its own reason.
        rig.pause.reason = .sleep
        await rig.tick()
        #expect(pauses(try rig.observed()).last?.reason == .sleep)
    }

    @Test("STORE: a lost Screen Recording grant writes permission_change and AX capture continues")
    func lostScreenRecordingKeepsAccessibility() async throws {
        let rig = Rig()
        rig.ax.text = "short text from accessibility"
        rig.ocr.text = "ocr text"
        await rig.tick()
        #expect(rig.ocr.calls == 1)
        #expect(permissionChanges(try rig.observed()).isEmpty, "the first reading is the baseline, not a change")

        rig.permissions.state = PermissionState(screenRecording: false, accessibility: true)
        await rig.tick(5)
        let changes = permissionChanges(try rig.observed())
        #expect(changes.count == 1)
        #expect(changes.first?.perm.screenRecording == false)
        #expect(changes.first?.perm.accessibility == true)

        rig.ax.text = "new accessibility text after the grant was lost"
        await rig.tick(31)
        let last = snapshots(try rig.observed()).last
        #expect(last?.textSource == .ax)
        #expect(last?.text == "new accessibility text after the grant was lost")
        #expect(rig.ocr.calls == 1, "no OCR without Screen Recording")
        // No second change event while nothing changes.
        await rig.tick(6)
        #expect(permissionChanges(try rig.observed()).count == 1)
    }
}
