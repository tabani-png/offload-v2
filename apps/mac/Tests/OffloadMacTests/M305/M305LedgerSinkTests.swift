import Foundation
import Testing
@testable import OffloadImport
@testable import OffloadMac

// The fingerprint ledger (PR #44 S34LedgerTests) and the import sink's wire shapes (m1-02 contracts, API.md).
extension M305 {
  // MARK: LEDGER

  @Test("LEDGER: aFileIsIngestedOnceAndTheLedgerHoldsNoNames, file 0600 in a 0700 folder")
  func aFileIsIngestedOnceAndTheLedgerHoldsNoNames() throws {
    let root = M305Files.folder("Support")
    defer { M305Files.remove(root) }
    let file = root.appendingPathComponent("imports/ledger.json")
    let ledger = FileRecordingLedger(file: file)
    let fp = RecordingFingerprint.of(path: "/Users/m/Desktop/Screen Recording 2026-11-13 at 9.41.07 AM.mov",
                                     size: 1234, modified: Date(timeIntervalSince1970: 1_792_490_400))
    #expect(!ledger.contains(fp))
    try ledger.record(RecordingLedgerEntry(fingerprint: fp, importID: "imp-1", ingestedAt: M305Clock.now,
                                           recordedAt: M305Clock.now, moments: 12))
    #expect(FileRecordingLedger(file: file).contains(fp))
    let raw = try String(contentsOf: file, encoding: .utf8)
    #expect(!raw.contains("Screen Recording"))
    #expect(!raw.contains("/Users/"))
    #expect(!raw.contains("Desktop"))
    let fileMode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
    #expect(fileMode?.intValue == 0o600)
    let dirMode = try FileManager.default.attributesOfItem(atPath: file.deletingLastPathComponent().path)[.posixPermissions] as? NSNumber
    #expect(dirMode?.intValue == 0o700)
  }

  @Test("LEDGER: fingerprintChangesWhenTheFileChanges (size or modified time), 64 hex characters")
  func fingerprintChangesWhenTheFileChanges() {
    let d = Date(timeIntervalSince1970: 1)
    let one = RecordingFingerprint.of(path: "/a.mov", size: 1, modified: d)
    let two = RecordingFingerprint.of(path: "/a.mov", size: 2, modified: d)
    let three = RecordingFingerprint.of(path: "/a.mov", size: 1, modified: d.addingTimeInterval(1))
    #expect(one != two)
    #expect(one != three)
    #expect(one.count == 64)
    #expect(one.allSatisfy { "0123456789abcdef".contains($0) })
    #expect(one == RecordingFingerprint.of(path: "/a.mov", size: 1, modified: d))
  }

  @Test("LEDGER: removing an import's entries lets its files be read again; other imports keep theirs")
  func removeEntriesForAnImport() throws {
    let root = M305Files.folder("Support")
    defer { M305Files.remove(root) }
    let ledger = FileRecordingLedger(file: root.appendingPathComponent("imports/ledger.json"))
    try ledger.record(RecordingLedgerEntry(fingerprint: "a", importID: "one", ingestedAt: M305Clock.now, recordedAt: M305Clock.now, moments: 1))
    try ledger.record(RecordingLedgerEntry(fingerprint: "b", importID: "two", ingestedAt: M305Clock.now, recordedAt: M305Clock.now, moments: 1))
    try ledger.removeEntries(importID: "one")
    #expect(!ledger.contains("a"))
    #expect(ledger.contains("b"))
    #expect(!FileRecordingLedger(file: root.appendingPathComponent("imports/ledger.json")).contains("a"))
  }

  @Test("LEDGER: the memory ledger keeps the same rules")
  func memoryLedger() throws {
    let ledger = MemoryRecordingLedger()
    try ledger.record(RecordingLedgerEntry(fingerprint: "a", importID: "one", ingestedAt: M305Clock.now, recordedAt: M305Clock.now, moments: 3))
    #expect(ledger.contains("a"))
    #expect(ledger.entries.count == 1)
    try ledger.removeEntries(importID: "one")
    #expect(ledger.entries.isEmpty)
  }

  // MARK: SINK

  @Test("SINK: POST /v1/imports sends { source_kind } and POST /v1/me/forget sends { scope: import, import_id }")
  func requestBodies() throws {
    let enc = JSONEncoder()
    enc.outputFormatting = [.sortedKeys]
    let create = try enc.encode(CreateImportRequest(sourceKind: .videos))
    #expect(String(decoding: create, as: UTF8.self) == #"{"source_kind":"videos"}"#)
    let forget = try enc.encode(ForgetImportRequest(importID: "8d0f2f4e-0000-4000-8000-000000000001"))
    #expect(String(decoding: forget, as: UTF8.self) == #"{"import_id":"8d0f2f4e-0000-4000-8000-000000000001","scope":"import"}"#)
    let reply = try JSONDecoder().decode(CreateImportResponse.self, from: Data(#"{"import_id":"8d0f2f4e-0000-4000-8000-000000000001"}"#.utf8))
    #expect(reply.importID == "8d0f2f4e-0000-4000-8000-000000000001")
    #expect(ImportSourceKind.allCases.map(\.rawValue) == ["screenwatch", "screenshots", "videos"])
  }

  @Test("SINK: observations match the m1-02 keys: snake case, RFC 3339 ts, ULID id, source import, import_id, no url")
  func observationJSON() throws {
    let ids = ULIDGenerator()
    let at = M305Clock.date(2026, 11, 13, 9, 41, 7)
    let focus = ImportObservation.focus(id: ids.next(at: at), ts: at, importID: "imp", appBundleID: "com.google.Chrome",
                                        appName: "Google Chrome", title: "Inbox", host: "mail.google.com")
    let f = try m305JSON(focus)
    #expect(Set(f.keys) == ["id", "ts", "kind", "source", "import_id", "app_bundle_id", "app_name", "title", "host"])
    #expect(f["kind"] as? String == "focus")
    #expect(f["source"] as? String == "import")
    #expect(f["import_id"] as? String == "imp")
    #expect(f["ts"] as? String == "2026-11-13T09:41:07.000Z")
    let id = try #require(f["id"] as? String)
    #expect(id.range(of: "^[0-9A-HJKMNP-TV-Z]{26}$", options: .regularExpression) != nil)
    let idle = try m305JSON(ImportObservation.idle(.idleStart, id: ids.next(at: at), ts: at, importID: "imp"))
    #expect(Set(idle.keys) == ["id", "ts", "kind", "source", "import_id"])
    #expect(idle["kind"] as? String == "idle_start")
    #expect(try m305JSON(ImportObservation.idle(.idleEnd, id: ids.next(at: at), ts: at, importID: "imp"))["kind"] as? String == "idle_end")
  }

  @Test("SINK: a text snapshot carries text, text_hash = SHA-256 hex of the text and text_source ocr")
  func textSnapshotJSON() throws {
    let at = M305Clock.now
    let o = ImportObservation.text(id: ULIDGenerator().next(at: at), ts: at, importID: "imp", appBundleID: "com.apple.Safari",
                                   text: "Invoice <num> from Acme")
    let j = try m305JSON(o)
    #expect(Set(j.keys) == ["id", "ts", "kind", "source", "import_id", "app_bundle_id", "text", "text_hash", "text_source"])
    #expect(j["kind"] as? String == "text_snapshot")
    #expect(j["text_source"] as? String == "ocr")
    #expect(j["text_hash"] as? String == m305Sha256("Invoice <num> from Acme"))
    #expect(o.textHash == m305Sha256("Invoice <num> from Acme"))
  }

  @Test("SINK: ULIDs are 26 characters, unique and ordered by time")
  func ulids() {
    let ids = ULIDGenerator()
    let a = ids.next(at: M305Clock.now)
    let b = ids.next(at: M305Clock.now)
    let c = ids.next(at: M305Clock.now.addingTimeInterval(1))
    #expect(a.count == 26 && b.count == 26)
    #expect(a != b)
    #expect(a.prefix(10) == b.prefix(10))
    #expect(c > a && c > b)
  }

  @Test("SINK: the in-memory sink opens an import space with a UUID, keeps writes per space and refuses unknown ones")
  func inMemorySink() async throws {
    let sink = InMemoryImportSink()
    let space = try await sink.openImport(sourceKind: .screenshots)
    #expect(space.sourceKind == .screenshots)
    #expect(UUID(uuidString: space.id) != nil)
    #expect(space.id == space.id.lowercased())
    let at = M305Clock.now
    try sink.write([ImportObservation.idle(.idleEnd, id: ULIDGenerator().next(at: at), ts: at, importID: space.id)], to: space)
    #expect(sink.observations(in: space.id).count == 1)
    #expect(throws: (any Error).self) {
      try sink.write([], to: ImportSpace(id: "00000000-0000-4000-8000-000000000000", sourceKind: .videos))
    }
    try await sink.forget(space)
    #expect(sink.forgotten == [space.id])
    #expect(sink.observations(in: space.id).isEmpty)
  }

  @Test("SINK: Remove imported data forgets the import space and clears its ledger entries")
  @MainActor func removeImportedData() async throws {
    let folder = M305Files.folder("Desktop")
    defer { M305Files.remove(folder) }
    M305Files.put(folder, "Screen Recording 2026-11-13 at 9.41.07 AM.mov")
    let fakes = M305Importer()
    let ui = M305UI()
    ui.store.folder = folder
    let model = ui.model(importer: fakes, suggested: folder)
    #expect(model.startImport())
    await model.waitForImport()
    let record = try #require(model.imports.first)
    #expect(!fakes.ledger.entries.isEmpty)
    await model.remove(record)
    #expect(fakes.sink.forgotten == [record.space.id])
    #expect(fakes.ledger.entries.isEmpty)
    #expect(model.imports.isEmpty)
    #expect(ui.store.imports.isEmpty)
  }
}
