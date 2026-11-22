import Foundation
import Testing
@testable import OffloadMac
import OffloadContracts
import OffloadImport
import OffloadMasker
import OffloadStore

// The recordings import with the real masker and, when this Mac sends, the uploader as its only way out
// (SPEC: "Recordings import", "Seams for m3-10"; W1-D audit gap 1).

private struct LoadFailed: Error {}

extension M314 {
  static let maskInput = "Write to ana.lopez@example.com about card 4111 1111 1111 1111 today"

  @Test("IMPORT: the import masker is the capture masker: secrets and emails are masked before anything is written")
  @MainActor func realMasker() throws {
    let secrets = MemorySecretStore()
    let capture = CaptureRuntime(home: M314Fixture.tempHome(), neverWatch: NeverWatchStore(), secrets: secrets, ticks: false)
    let masker = capture.importMasker()
    // The pseudonym key is made when the first text is masked, not when the app starts.
    #expect(try secrets.read(account: "pseudonym-key") == nil)
    let out = masker.mask(Self.maskInput)
    #expect(!out.contains("ana.lopez@example.com"))
    #expect(!out.contains("4111"))
    #expect(out.contains("today"))
    let key = try #require(try secrets.read(account: "pseudonym-key"))
    let live = TextMasker(pseudonymizer: Pseudonymizer(key: PseudonymKey(data: key)))
    #expect(out == live.mask(Self.maskInput).text)
    // Fail closed: a masker that cannot load its key writes no text at all.
    #expect(ImportMaskerAdapter(load: { throw LoadFailed() }).mask(Self.maskInput) == "")
  }

  @Test("IMPORT: without a text recognizer or a sink there is no importer")
  @MainActor func importerNeedsRecognizerAndSink() {
    let masker = ImportMaskerAdapter(masker: TextMasker(pseudonymizer: Pseudonymizer(key: PseudonymKey(data: Data(repeating: 7, count: 32)))))
    let never = NeverWatchStore()
    #expect(ImportComposition.importer(recognizer: nil, masker: masker, sink: InMemoryImportSink(),
                                       ledger: MemoryRecordingLedger(), neverWatch: never, protected: []) == nil)
    #expect(ImportComposition.importer(recognizer: M314Recognizer(), masker: masker, sink: nil,
                                       ledger: MemoryRecordingLedger(), neverWatch: never, protected: []) == nil)
    #expect(ImportComposition.importer(recognizer: M314Recognizer(), masker: masker, sink: InMemoryImportSink(),
                                       ledger: MemoryRecordingLedger(), neverWatch: never, protected: []) != nil)

    // This build (no recognizer from m3-10): Local mode gets no importer and no sink, as before.
    let none = M314Wiring()
    let a = M314App.composition(state: M314State.watchingLocally, wiring: none)
    defer { a.capture.stop() }
    #expect(none.importer == nil)
    #expect(none.sink == nil)
    // m3-10 plugs its recognizer and its local sink in: Local mode imports on the Mac.
    let local = M314Wiring()
    let b = M314App.composition(state: M314State.watchingLocally,
                                seams: CompositionSeams(textRecognizer: M314Recognizer(), onDeviceImportSink: M314LocalSink()),
                                wiring: local)
    defer { b.capture.stop() }
    #expect(local.importer != nil)
    #expect(local.sink is M314LocalSink)
    // Sending from an enrolled Mac: the uploader is the sink, even when m3-10 offers a local one.
    let cloud = M314Wiring()
    let c = M314App.composition(backend: M314Fixture.cloud, state: M314State.sending, currentNoticeVersion: "1",
                                seams: CompositionSeams(textRecognizer: M314Recognizer(), onDeviceImportSink: M314LocalSink()),
                                wiring: cloud)
    defer {
      c.capture.stop()
      c.uploads?.pause()
    }
    #expect(cloud.sink is UploaderImportSink)
    #expect(cloud.importer != nil)
  }

  /// The same objects as contract observations (what the sink hands to the uploader).
  static func importObjects(_ importID: String) -> [Observation] {
    observations(importID).map { o in
      (try? JSONDecoder().decode(Observation.self, from: JSONEncoder().encode(o)))!
    }
  }

  static func observations(_ importID: String) -> [ImportObservation] {
    let ids = OffloadImport.ULIDGenerator()
    let t0 = M314Fixture.t0
    return [
      .focus(id: ids.next(at: t0), ts: t0, importID: importID, appBundleID: "com.apple.Safari", appName: "Safari",
             title: "Release notes"),
      .text(id: ids.next(at: t0.addingTimeInterval(5)), ts: t0.addingTimeInterval(5), importID: importID,
            appBundleID: "com.apple.Safari", text: "Masked text only"),
      .idle(.idleStart, id: ids.next(at: t0.addingTimeInterval(130)), ts: t0.addingTimeInterval(130), importID: importID),
    ]
  }

  @Test("IMPORT: the uploader-backed sink opens the space through the uploader and queues closed-schema import objects")
  func uploaderSinkQueues() async throws {
    let queue = FakeImportQueue()
    let sink = UploaderImportSink(queue: queue)
    let space = try await sink.openImport(sourceKind: .videos)
    #expect(space == ImportSpace(id: M314Fixture.importID, sourceKind: .videos))
    #expect(queue.opened == ["videos"])

    try sink.write(Self.observations(space.id), to: space)
    try sink.write([], to: space)
    // Staged before write returns: nothing is left in flight.
    let queued = queue.staged
    #expect(queued.count == 1)
    let objects = try #require(queued.first)
    #expect(objects.map(\.kind) == ["focus", "text_snapshot", "idle_start"])
    #expect(objects.allSatisfy { UploaderImportSink.importID(of: $0) == space.id })
    #expect(objects.allSatisfy { UploaderImportSink.source(of: $0) == .import })
    if case .textSnapshot(let t) = objects[1] {
      #expect(t.text == "Masked text only")
      #expect(t.textSource == .ocr)
    } else {
      Issue.record("the second object is not a text snapshot")
    }
  }

  @Test("IMPORT: the uploader-backed sink refuses an unknown space and objects of another space")
  func uploaderSinkRefuses() async throws {
    let queue = FakeImportQueue()
    let sink = UploaderImportSink(queue: queue)
    let unknown = ImportSpace(id: "imp_never_opened", sourceKind: .screenshots)
    #expect(throws: ImportUploadRefusal.self) { try sink.write(Self.observations(unknown.id), to: unknown) }
    let space = try await sink.openImport(sourceKind: .screenwatch)
    #expect(throws: ImportUploadRefusal.self) { try sink.write(Self.observations(M314Fixture.otherImportID), to: space) }
    #expect(queue.staged.isEmpty)
  }

  @Test("IMPORT: forgetting an import goes through the uploader")
  func uploaderSinkForgets() async throws {
    let queue = FakeImportQueue()
    let sink = UploaderImportSink(queue: queue)
    let space = try await sink.openImport(sourceKind: .videos)
    try await sink.forget(space)
    #expect(queue.forgotten == [space.id])
    #expect(throws: ImportUploadRefusal.self) { try sink.write(Self.observations(space.id), to: space) }
  }

  @Test("IMPORT: a refused hand-off fails the write, so nothing is half queued")
  func refusedHandOffFailsTheWrite() async throws {
    let queue = FakeImportQueue()
    let sink = UploaderImportSink(queue: queue)
    let space = try await sink.openImport(sourceKind: .videos)
    queue.refuseStaging = true
    #expect(throws: ImportUploadRefusal.self) { try sink.write(Self.observations(space.id), to: space) }
    #expect(queue.staged.isEmpty)
    queue.refuseStaging = false
    try sink.write(Self.observations(space.id), to: space)
    #expect(queue.staged.count == 1)
  }

  @Test("IMPORT: when the uploader refuses a file, the importer does not record it, so the next import reads it again")
  func importerDoesNotRecordARefusedFile() async throws {
    let root = M305Files.folder()
    defer { M305Files.remove(root) }
    M305Files.screenwatchDay(root, "2026-09-01", start: (9, 0), minutes: 10, apps: M305Files.watchApps)
    let queue = FakeImportQueue()
    queue.refuseStaging = true
    var fakes = M305Importer()
    fakes.customSink = UploaderImportSink(queue: queue)
    let refused = await fakes.run(root)
    #expect((refused.report?.failed ?? 0) > 0)
    #expect(fakes.ledger.entries.isEmpty)
    #expect(queue.staged.isEmpty)

    queue.refuseStaging = false
    let accepted = await fakes.run(root)
    #expect(accepted.report?.filesRead == 1)
    #expect(fakes.ledger.entries.count == 1)
    #expect(!queue.staged.isEmpty)
  }

  @Test("IMPORT: the import is offered by where it goes: on this Mac once an on-device sink exists, through the uploader only while sending")
  @MainActor func importOffer() {
    // Before screen 2 is resolved, even with an on-device sink: not offered (no folder read at launch, no prompt).
    let early = M314App.composition(state: M314State.fresh,
                                    seams: CompositionSeams(textRecognizer: M314Recognizer(), onDeviceImportSink: M314LocalSink()),
                                    realRecordings: true)
    defer { early.capture.stop() }
    #expect(early.app.recordings?.isOffered == false)
    // This build: no on-device sink, Local mode: not offered (and the menu says the import is coming).
    let none = M314App.composition(state: M314State.watchingLocally, realRecordings: true)
    defer { none.capture.stop() }
    #expect(none.app.recordings?.isOffered == false)
    // m3-10 plugs in OCR and a local sink: offered in Local mode, nothing leaves the Mac (owner goal 2026-11-22;
    // ONBOARDING section 8 divergence recorded in the SPEC).
    let seams = CompositionSeams(textRecognizer: M314Recognizer(), onDeviceImportSink: M314LocalSink())
    let local = M314App.composition(state: M314State.watchingLocally, seams: seams, realRecordings: true)
    defer { local.capture.stop() }
    #expect(local.app.recordings?.isOffered == true)
    #expect(local.app.recordings?.canImport == true)
    #expect(local.modeLines == [ModeLines.local])
    // An enrolled Mac that is sending: through the uploader, offered while sending.
    let cloud = M314App.composition(backend: M314Fixture.cloud, state: M314State.sending, currentNoticeVersion: "1",
                                    seams: seams, realRecordings: true)
    defer {
      cloud.capture.stop()
      cloud.uploads?.pause()
    }
    #expect(cloud.importChoice == .uploader)
    #expect(cloud.app.recordings?.isOffered == true)
    // A changed notice withdraws the uploader-backed import at once.
    cloud.app.onboarding.reconsentNeeded()
    #expect(cloud.app.recordings?.isOffered == false)
  }

  @Test("IMPORT: the offer rule: on this Mac only after screen 2, through the uploader never while a new notice waits")
  @MainActor func offerRuleCases() {
    var fresh = M314State.fresh
    #expect(!ImportOffer.isOffered(choice: .onDevice, hasOnDeviceSink: true, uploadsAvailable: false, state: fresh))
    fresh.screen = .permissions
    #expect(!ImportOffer.isOffered(choice: .onDevice, hasOnDeviceSink: true, uploadsAvailable: false, state: fresh))
    #expect(ImportOffer.isOffered(choice: .onDevice, hasOnDeviceSink: true, uploadsAvailable: false,
                                  state: M314State.watchingLocally))
    #expect(!ImportOffer.isOffered(choice: .onDevice, hasOnDeviceSink: false, uploadsAvailable: false,
                                   state: M314State.watchingLocally))
    var done = M314State.fresh
    done.completed = true
    #expect(ImportOffer.isOffered(choice: .onDevice, hasOnDeviceSink: true, uploadsAvailable: false, state: done))
    // The launch path: consent still on record, but a new notice is pending (LaunchFacts' reconsent case).
    var pending = M314State.sending
    pending.reconsentPending = true
    #expect(pending.sending)
    #expect(!ImportOffer.isOffered(choice: .uploader, hasOnDeviceSink: false, uploadsAvailable: true, state: pending))
    #expect(ImportOffer.isOffered(choice: .uploader, hasOnDeviceSink: false, uploadsAvailable: true, state: M314State.sending))
    #expect(!ImportOffer.isOffered(choice: .uploader, hasOnDeviceSink: false, uploadsAvailable: false, state: M314State.sending))
  }
}
