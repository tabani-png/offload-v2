import Foundation
import Testing
@testable import OffloadImport
@testable import OffloadMac

// Review 6 (logs/m3-10-mac-recordings-analysis.review6.md): an app name the name tagger reports as a person is kept
// when it is a known or installed app, so a recording's app is not turned into "Screen" (finding 1); masking an input
// seen before does not run the tagger again (finding 2); review 4's open items: URL user info is dropped (its finding
// 3), and an import run with no focus of its own is not charged to the previous file's app (its finding 2).

/// Counts the texts it is asked about; reports nothing.
final class M310CountingNames: PersonNameFinder, @unchecked Sendable {
  private let lock = NSLock()
  private var n = 0
  var calls: Int {
    lock.lock()
    defer { lock.unlock() }
    return n
  }
  func personNames(in text: String) -> [Range<String.Index>] {
    lock.lock()
    n += 1
    lock.unlock()
    return []
  }
}

extension M310 {
  // MARK: Finding 1: app names are not people

  @Test("MASK: known and installed app names stay even when the name finder reports them; a person beside them is masked")
  func appNamesAreNotPeople() {
    let finder = M310Names(names: ["Quicken", "Brave", "Sublime", "Alfred", "Hazel", "Amara Okafor"])
    let m = InterimTextMasker(key: m310Key, names: finder, appNames: ["Sublime Text", "Alfred", "Hazel"])
    for app in ["Quicken", "Brave Browser", "Sublime Text", "Alfred", "Hazel"] {
      #expect(m.mask(app) == app, "\(app)")
    }
    #expect(m.mask("Opened Alfred and Hazel") == "Opened Alfred and Hazel")
    #expect(m.mask("Opened Alfred for Amara Okafor") == "Opened Alfred for \(m.personPseudonym("Amara Okafor"))")
  }

  @Test("WIRING: a recording whose menu bar shows an installed app the name tagger calls a person keeps that app's name")
  @MainActor func installedAppKeepsItsName() async throws {
    let root = M310Files.folder()
    defer { M310Files.remove(root) }
    let script = M305Script(id: "rec", duration: 60, scenes: [
      M305Scene(at: 0, lines: m305Screen(app: "Alfred", body: "Clipboard history"), hash: 0),
    ])
    let readers = RecordingImporter.Readers(
      openVideo: { _ in FakeRecording(script) },
      openImage: { url in ImportFrame(width: 1280, height: 800, tag: url.lastPathComponent) }
    )
    let ui = M305UI()
    ui.store.folder = Self.recordingsFolder(root)
    let folders = OnDeviceRecordings.Folders(home: root.appendingPathComponent("home"), screencaptureLocation: nil,
                                             paths: OnDevicePaths(offloadSupport: root.appendingPathComponent("Offload")))
    let made = try OnDeviceRecordings.make(neverWatch: NeverWatchStore(), store: ui.store, folders: folders, panel: ui.panel,
                                           picker: ui.picker, recognizer: ScriptedRecognizer([script]), pseudonymKey: m310Key,
                                           readers: readers, clock: FakeClock(), timeZone: M310Clock.utc,
                                           durations: { _ in 60 }, appNames: nil,
                                           nameFinder: M310Names(names: ["Alfred"]), installedAppNames: ["Alfred"])
    made.model.offerCheck = { true }
    let started = await made.model.startImport()
    #expect(started)
    await made.model.waitForImport()
    let id = try #require(made.observations.importIDs().first)
    let focus = made.observations.stored(importID: id).filter { $0.kind == "focus" }
    #expect(focus.map(\.appName) == ["Alfred"])
  }

  @Test("FOLDERS: installed app names are the .app bundles of the Applications folders, without the extension")
  func installedAppNamesList() throws {
    let root = M310Files.folder("home")
    defer { M310Files.remove(root) }
    let apps = root.appendingPathComponent("Applications", isDirectory: true)
    for name in ["Alfred 5.app", "Hazel.app", "notes.txt"] {
      try FileManager.default.createDirectory(at: apps.appendingPathComponent(name), withIntermediateDirectories: true)
    }
    #expect(InstalledAppNames.list(folders: [apps, root.appendingPathComponent("Missing")]) == ["Alfred 5", "Hazel"])
  }

  // MARK: Finding 2: the tagger runs once per distinct short input

  @Test("MASK: masking a title seen before does not run the name finder again")
  func maskMemoised() {
    let finder = M310CountingNames()
    let m = InterimTextMasker(key: m310Key, names: finder)
    for _ in 0..<100 { _ = m.mask("Inbox - Gmail") }
    #expect(finder.calls == 1)
    _ = m.mask("Re: Invoice - Gmail")
    #expect(finder.calls == 2)
    #expect(m.mask("Inbox - Gmail") == "Inbox - Gmail")
    #expect(finder.calls == 2)
  }

  // MARK: Review 4's open items

  @Test("MASK: user info in a URL is dropped; the host and the doc pseudonym stay")
  func urlUserInfoDropped() {
    let m = InterimTextMasker(key: m310Key, names: M310Names(names: []))
    let doc = m.pseudonym("doc", "db.example.com/x")
    #expect(m.mask("see https://bob:hunter!2@db.example.com/x now") == "see https://db.example.com/\(doc) now")
    #expect(m.mask("open https://amara@mail.example.com") == "open https://mail.example.com")
  }

  @Test("INSIGHTS: an import run with no focus of its own is not charged to the previous file's app")
  func runWithoutFocusCountsNothing() {
    var e = M310Events(origin: .imported("imp-1"), prefix: "n")
    e.idleEnd(M310Clock.date(2026, 11, 18, 9))
    e.focus(M310Clock.date(2026, 11, 18, 9), M310App.xcode)
    e.idleStart(M310Clock.date(2026, 11, 18, 9, 12))     // Xcode 9:00 to 9:10
    e.idleEnd(M310Clock.date(2026, 11, 18, 10))          // a recording with no readable frame
    e.text(M310Clock.date(2026, 11, 18, 10, 5))
    e.idleStart(M310Clock.date(2026, 11, 18, 10, 22))
    let d = LocalInsights.day(e.events, day: "2026-11-18", timeZone: M310Clock.utc, exclusions: [])
    #expect(d.activeSeconds.value == 600)
    #expect(d.perApp.map(\.appName) == ["Xcode"])
  }
}
