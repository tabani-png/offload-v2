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
    #expect(space == ImportSpace(id: "imp_m314", sourceKind: .videos))
    #expect(await queue.opened == ["videos"])

    try sink.write(Self.observations(space.id), to: space)
    try sink.write([], to: space)
    await sink.drain()
    let queued = await queue.queued
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
    #expect(throws: UnknownImportSpace.self) { try sink.write(Self.observations(unknown.id), to: unknown) }
    let space = try await sink.openImport(sourceKind: .screenwatch)
    #expect(throws: ImportUploadRefusal.self) { try sink.write(Self.observations("imp_other"), to: space) }
    await sink.drain()
    #expect(await queue.queued.isEmpty)
  }

  @Test("IMPORT: forgetting an import goes through the uploader")
  func uploaderSinkForgets() async throws {
    let queue = FakeImportQueue()
    let sink = UploaderImportSink(queue: queue)
    let space = try await sink.openImport(sourceKind: .videos)
    try await sink.forget(space)
    #expect(await queue.forgotten == [space.id])
    #expect(throws: UnknownImportSpace.self) { try sink.write(Self.observations(space.id), to: space) }
  }
}
