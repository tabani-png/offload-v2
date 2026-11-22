import Foundation
import Testing
@testable import OffloadMac
import OffloadStore

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
  @MainActor func oneCapture() {
    let wiring = M314Wiring()
    let home = M314Fixture.tempHome()
    let c = M314App.composition(state: M314State.watchingLocally, home: home, wiring: wiring)
    defer { c.capture.stop() }
    #expect((wiring.captureForUpdates as AnyObject?) === c.capture)
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
}
