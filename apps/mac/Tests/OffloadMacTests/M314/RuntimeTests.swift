import Foundation
import Testing
@testable import OffloadMac
import OffloadContracts
import OffloadObserver
import OffloadStore
import OffloadUploader

// The capture and upload runtimes and how the composition root hands them out (SPEC: "CaptureRuntime",
// "UploadRuntime", Design note).

extension M314 {
  // MARK: CAPTURE

  @Test("CAPTURE: the capture runtime creates nothing on disk until it is started")
  @MainActor func nothingBeforeStart() throws {
    let home = M314Fixture.tempHome()
    let secrets = MemorySecretStore()
    let capture = CaptureRuntime(home: home, neverWatch: NeverWatchStore(), secrets: secrets, ticks: false)
    #expect(!capture.isRunning)
    #expect(capture.store.current == nil)
    #expect(capture.events.captureStartedAt() == nil)
    #expect(capture.events.events(from: 0, to: Int64.max) == [])
    #expect(!FileManager.default.fileExists(atPath: home.path))
    #expect(try secrets.read(account: "pseudonym-key") == nil)

    // A composition that has not been told to capture (fresh state) builds nothing either.
    let freshHome = M314Fixture.tempHome()
    let fresh = M314App.composition(state: M314State.fresh, home: freshHome)
    #expect(!fresh.capture.isRunning)
    #expect(!FileManager.default.fileExists(atPath: freshHome.path))

    // Started: the encrypted store and the Never watch file exist, and the store is the one the now line reads.
    capture.start()
    defer { capture.stop() }
    #expect(capture.isRunning)
    #expect(capture.lastError == nil)
    #expect(capture.store.current != nil)
    #expect(FileManager.default.fileExists(atPath: StoreLayout(home: home).daysDir.path))
    #expect(FileManager.default.fileExists(atPath: StoreLayout(home: home).exclusionsFile.path))
    capture.prepareForUpdate()
    #expect(!capture.isRunning)
  }

  @Test("CAPTURE: the composition gives the updater and the app the same capture runtime")
  @MainActor func oneCapture() throws {
    let wiring = M314Wiring()
    let home = M314Fixture.tempHome()
    let c = M314App.composition(state: M314State.watchingLocally, home: home, wiring: wiring)
    defer { c.capture.stop() }
    // The updater gets the composition's update preparation, which drives this same capture runtime.
    let prep = try #require(wiring.lifecycleForUpdates as? UpdatePreparation)
    #expect(prep.capture === c.capture)
    #expect((c.app.onboarding.services.capture as AnyObject) === c.capture)
    // Screen 2 was resolved before this launch: capture started at launch, on this Mac only.
    #expect(c.capture.isRunning)
    #expect(c.app.isCapturing)
    #expect(c.app.launchPlan.startCapture)
    #expect(c.backend == .local)
  }

  // MARK: UPLOAD

  @Test("UPLOAD: Local mode has no upload runtime and Start sending starts nothing that sends")
  @MainActor func localHasNoUploader() async {
    let c = M314App.composition(backend: .local, state: M314State.sending, currentNoticeVersion: "1")
    defer { c.capture.stop() }
    #expect(c.uploads == nil)
    #expect(c.app.onboarding.services.uploader is NoUploader)
    #expect(!c.app.launchPlan.startUploader)
    #expect(c.importChoice == .onDevice)
    // Starting the uploader the onboarding way does nothing that sends.
    c.app.onboarding.services.uploader.start()
    #expect(c.uploads == nil)
  }

  @Test("UPLOAD: the upload runtime pauses its turns when the notice changes")
  @MainActor func uploaderPausesOnNoticeChange() {
    let c = M314App.composition(backend: M314Fixture.cloud, state: M314State.sending, currentNoticeVersion: "1")
    defer {
      c.capture.stop()
      c.uploads?.pause()
    }
    guard let uploads = c.uploads else {
      Issue.record("no upload runtime in cloud mode")
      return
    }
    #expect((c.app.onboarding.services.uploader as AnyObject) === uploads)
    #expect(uploads.isRunning)
    #expect(c.importChoice == .uploader)
    #expect(c.app.launchPlan == LaunchPlan(startUpdater: true, startCapture: true, startUploader: true, importSink: .uploader))
    // Row 11.11: a new "What leaves your Mac" version pauses uploads; capture stays local.
    c.app.onboarding.reconsentNeeded()
    #expect(!uploads.isRunning)
    #expect(c.capture.isRunning)

    // Launched with the new version already known: the uploader never starts.
    let changed = M314App.composition(backend: M314Fixture.cloud, state: M314State.sending, currentNoticeVersion: "2")
    defer { changed.capture.stop() }
    #expect(changed.uploads?.isRunning == false)
    #expect(changed.importChoice == .onDevice)
  }

  @Test("UPLOAD: before an update, capture stops and the uploader pauses")
  @MainActor func updateStopsBoth() throws {
    let wiring = M314Wiring()
    let c = M314App.composition(backend: M314Fixture.cloud, state: M314State.sending, currentNoticeVersion: "1",
                                wiring: wiring)
    defer {
      c.capture.stop()
      c.uploads?.pause()
    }
    let uploads = try #require(c.uploads)
    #expect(c.capture.isRunning && uploads.isRunning)
    let prep = try #require(wiring.lifecycleForUpdates)
    prep.prepareForUpdate()
    #expect(!c.capture.isRunning)
    #expect(!uploads.isRunning)
    // Local mode: there is no uploader to pause, and capture still stops.
    let local = M314Wiring()
    let l = M314App.composition(state: M314State.watchingLocally, wiring: local)
    try #require(local.lifecycleForUpdates).prepareForUpdate()
    #expect(!l.capture.isRunning)
  }

  @Test("UPLOAD: a paused upload runtime refuses to open or stage an import; a running one stages on this Mac")
  @MainActor func pausedRefusesImports() async throws {
    let uploads = UploadRuntime(apiBase: M314Fixture.apiBase, deviceID: "dev_m314",
                                context: StoreContext(home: M314Fixture.tempHome(), secrets: MemorySecretStore()), turns: false)
    let objects = M314.importObjects(M314Fixture.importID)
    await #expect(throws: ImportUploadRefusal.self) { try await uploads.openImport(sourceKind: "videos") }
    #expect(throws: ImportUploadRefusal.self) { try uploads.stageImport(objects) }
    #expect(try uploads.outbox.staged().isEmpty)
    uploads.start()
    defer { uploads.pause() }
    try uploads.stageImport(objects)
    #expect(try uploads.outbox.staged().map(\.id) == objects.map(\.id))
    uploads.pause()
    #expect(throws: ImportUploadRefusal.self) { try uploads.stageImport(objects) }
  }

  @Test("CAPTURE: capture and the uploader share one store context (one key ring, one day store)")
  @MainActor func oneStore() throws {
    let c = M314App.composition(backend: M314Fixture.cloud, state: M314State.sending, currentNoticeVersion: "1")
    defer {
      c.capture.stop()
      c.uploads?.pause()
    }
    let uploads = try #require(c.uploads)
    #expect(uploads.context === c.capture.context)
    #expect(c.capture.store.current === c.capture.context.dayStore)
  }

  @Test("CAPTURE: the buffer is unreadable when its day keys no longer open, and Start fresh deletes it")
  @MainActor func unreadableBufferAndStartFresh() throws {
    let home = M314Fixture.tempHome()
    #expect(StoreContext(home: home, secrets: MemorySecretStore()).bufferReadable())
    let secrets = MemorySecretStore()
    let context = StoreContext(home: home, secrets: secrets)
    try context.layout.ensureDirectories()
    let at = M314Fixture.t0
    try context.dayStore.append(.focus(ObservationFocus(id: M314Fixture.id(at), ts: Timestamp.format(at),
                                                        appBundleId: "com.apple.Notes", appName: "Notes")))
    #expect(StoreContext(home: home, secrets: secrets).bufferReadable())
    // Restored without the Keychain: the master key is gone, the day files stay.
    let restored = StoreContext(home: home, secrets: MemorySecretStore())
    #expect(!restored.bufferReadable())

    // The app routes to "Start fresh"; choosing it deletes the unreadable buffer, then capture can start again.
    let wiring = M314Wiring()
    let c = M314App.composition(state: M314State.watchingLocally, bufferReadable: false, home: home,
                                secrets: MemorySecretStore(), wiring: wiring)
    #expect(c.app.route == .startFresh)
    #expect(!c.capture.isRunning)
    c.app.startFresh()
    #expect(c.capture.context.bufferReadable())
    #expect(c.capture.context.dayStore.storedDays().isEmpty)
  }

  @Test("UPLOAD: the upload runtime's own uploader opens imports with a member token and sends staged objects from the shared outbox")
  @MainActor func runtimeUploaderEndToEnd() async throws {
    let secrets = MemorySecretStore()
    // An enrolled Mac: its device key is already stored (no Secure Enclave in tests).
    _ = try DeviceKey.loadOrCreate(secrets: secrets, preferSecureEnclave: false)
    let server = ImportServer()
    let network = UploadRuntime.Network(transport: server, session: { _, _, _, _, audience in
      StaticTokenProvider(token: "\(audience.rawValue)-tok")
    })
    let uploads = UploadRuntime(apiBase: M314Uploads.apiBase, deviceID: M314Uploads.deviceID,
                                context: StoreContext(home: M314Fixture.tempHome(), secrets: secrets), turns: false,
                                network: network)
    uploads.start()
    defer { uploads.pause() }
    let id = try await uploads.openImport(sourceKind: "videos")
    #expect(id == M314Uploads.importID)
    let objects = M314.importObjects(id)
    try uploads.stageImport(objects)
    let uploader = try uploads.uploader()
    let report = await uploader.flush()
    #expect(report.sentObjects == objects.count)
    let opens = server.requests.filter { $0.url.path == "/v1/imports" }
    #expect(opens.map { $0.headers["Authorization"] } == ["Bearer member-tok"])
    let batches = server.batchRequests
    #expect(!batches.isEmpty && batches.allSatisfy { $0.headers["Authorization"] == "Bearer device-tok" })
    let sent = batches.flatMap { r -> [String] in
      let json = (try? JSONSerialization.jsonObject(with: r.body ?? Data())) as? [String: Any] ?? [:]
      return (json["objects"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
    }
    #expect(sent == objects.map(\.id))
    #expect(try uploads.outbox.staged().isEmpty)
    #expect(uploads.outbox === uploads.context.importOutbox)
  }

  @Test("CAPTURE: the buffer check never writes to the Keychain, and a Keychain error is not read as an unreadable buffer")
  @MainActor func bufferCheckReadsOnly() throws {
    let home = M314Fixture.tempHome()
    let context = StoreContext(home: home, secrets: MemorySecretStore())
    try context.layout.ensureDirectories()
    let at = M314Fixture.t0
    try context.dayStore.append(.focus(ObservationFocus(id: M314Fixture.id(at), ts: Timestamp.format(at),
                                                        appBundleId: "com.apple.Notes", appName: "Notes")))
    // Restored without the Keychain: unreadable, and no new master key was written by asking.
    let restored = CountingSecrets()
    #expect(!StoreContext(home: home, secrets: restored).bufferReadable())
    #expect(restored.writes == 0)
    // A locked or denied Keychain: not "unreadable", so "Start fresh" never deletes a good buffer.
    #expect(StoreContext(home: home, secrets: FailingSecrets()).bufferReadable())
  }

  @Test("CAPTURE: Start fresh also forgets which recordings were read, so they can be imported again")
  @MainActor func startFreshForgetsTheImportLedger() throws {
    let context = StoreContext(home: M314Fixture.tempHome(), secrets: MemorySecretStore())
    try context.layout.ensureDirectories()
    try Data("{}".utf8).write(to: context.importLedgerFile)
    try context.discard()
    #expect(!FileManager.default.fileExists(atPath: context.importLedgerFile.path))
  }

  @Test("CAPTURE: one tick writes the Never watch list before the observer runs")
  @MainActor func tickSyncsNeverWatchFirst() async throws {
    let never = NeverWatchStore()
    let capture = CaptureRuntime(home: M314Fixture.tempHome(), neverWatch: never, secrets: MemorySecretStore(), ticks: false)
    capture.start()
    defer { capture.stop() }
    // Added after start: only the tick can write it.
    never.add([Exclusion(kind: .host, value: "bank.example")])
    let seen = M314Seen()
    let file = capture.exclusionsFile
    // Stands in for the observer's tick (no live sources run): records what the observer would read.
    capture.observerTick = { _ in seen.rules = (try? ExclusionsFile.read(file)) ?? [] }
    #expect(await capture.tickOnce())
    #expect(seen.rules.contains(ExclusionRule(kind: .host, value: "bank.example")))
    // Not started: nothing ticks and nothing is written (no file before consent).
    let idle = CaptureRuntime(home: M314Fixture.tempHome(), neverWatch: never, secrets: MemorySecretStore(), ticks: false)
    #expect(await idle.tickOnce() == false)
    #expect(!FileManager.default.fileExists(atPath: idle.exclusionsFile.path))
  }
}

/// What a stand-in observer tick saw.
@MainActor final class M314Seen {
  var rules: [ExclusionRule] = []
}

/// A Keychain that throws on every call (locked, or access denied).
final class FailingSecrets: SecretStore, @unchecked Sendable {
  struct Denied: Error {}
  func read(account: String) throws -> Data? { throw Denied() }
  func write(_ data: Data, account: String) throws { throw Denied() }
  func delete(account: String) throws { throw Denied() }
}
