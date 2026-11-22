import Foundation
import Testing
@testable import OffloadMac

// One entry point and the launch decisions (SPEC: Contract, "One entry point", "BackendMode", "LaunchPlan").

extension M314 {
  // MARK: ENTRY

  @Test("ENTRY: --self-check runs the self-check before anything else, --version prints the version, anything else starts the app")
  func entryCommand() {
    let info: [String: Any] = [
      "CFBundleShortVersionString": "0.3.0", "CFBundleVersion": "42", "CFBundleIdentifier": "ai.offload.mac",
      "OffloadCommit": "abc1234",
    ]
    #expect(EntryCommand.decide(arguments: ["/Applications/Offload.app/Contents/MacOS/Offload"], info: info) == .app)
    #expect(EntryCommand.decide(arguments: ["Offload", "--self-check"], info: info) == .selfCheck)
    #expect(EntryCommand.decide(arguments: ["Offload", "--self-check", "--version"], info: info) == .selfCheck)
    #expect(EntryCommand.decide(arguments: ["Offload", "--version"], info: info)
            == .version("Offload 0.3.0 (42) abc1234 ai.offload.mac"))
    #expect(EntryCommand.decide(arguments: ["Offload", "--version"], info: nil) == .version("Offload dev"))
    // Launch flags of the app itself are not commands.
    #expect(EntryCommand.decide(arguments: ["Offload", "--onboarding"], info: info) == .app)
  }

  @Test("ENTRY: the Mac sources hold exactly one @main, and only the composition root builds the app model, the updater and the runtimes")
  func oneEntryOneRoot() {
    let all = M314Fixture.swiftSources("Sources")
    #expect(all.count > 40)
    let mains = all.filter { f in f.text.split(separator: "\n").contains { $0.trimmingCharacters(in: .whitespaces) == "@main" } }
    #expect(mains.map(\.path) == ["Sources/OffloadMac/OffloadMac.swift"])
    // PR #13's file is gone: capture lives in the composition root now.
    #expect(!all.contains { $0.path == "Sources/OffloadMac/CaptureRuntime.swift" })

    let built = try! Regex(#"\b(AppModel|AppUpdates|CaptureRuntime|UploadRuntime)\(|AppModel\.live\(|RecordingsImportModel\.live\("#)
    let outside = all.filter { f in
      !f.path.hasPrefix("Sources/OffloadMac/Composition/") && f.text.split(separator: "\n").contains { line in
        let code = line.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
        return !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") && code.firstMatch(of: built) != nil
      }
    }
    // RecordingsImportModel.live is m3-05's own definition; it is defined there, never called outside the root.
    #expect(outside.map(\.path).filter { $0 != "Sources/OffloadMac/Recordings/LiveRecordings.swift" } == [])
    // The SwiftUI app asks the composition root for everything.
    let app = all.first { $0.path == "Sources/OffloadMac/App/OffloadApp.swift" }?.text ?? ""
    #expect(app.contains("AppComposition.live("))
  }

  // MARK: LAUNCH (LaunchPlan.decide is the one place the launch decisions are made)

  @Test("LAUNCH: before consent nothing starts but the updater")
  func beforeConsent() {
    for uploads in [false, true] {
      for notice in [nil, "1"] as [String?] {
        let facts = LaunchFacts(state: M314State.fresh, uploadsAvailable: uploads, bufferReadable: true,
                                currentNoticeVersion: notice)
        #expect(LaunchPlan.decide(facts)
                == LaunchPlan(startUpdater: true, startCapture: false, startUploader: false, importSink: .onDevice))
      }
    }
  }

  @Test("LAUNCH: after screen 2 capture starts in Local mode and the uploader does not")
  func localModeCaptures() {
    let local = LaunchPlan.decide(LaunchFacts(state: M314State.watchingLocally, uploadsAvailable: false,
                                              bufferReadable: true, currentNoticeVersion: nil))
    #expect(local == LaunchPlan(startUpdater: true, startCapture: true, startUploader: false, importSink: .onDevice))
    // A consented, signed-in person on a Mac without a backend (the test build) still sends nothing.
    let noBackend = LaunchPlan.decide(LaunchFacts(state: M314State.sending, uploadsAvailable: false,
                                                  bufferReadable: true, currentNoticeVersion: "1"))
    #expect(noBackend.startCapture)
    #expect(!noBackend.startUploader)
    #expect(noBackend.importSink == .onDevice)
    // Enrolled but not consented ("Keep it on this Mac").
    var keptLocal = M314State.sending
    keptLocal.uploadConsent = false
    let kept = LaunchPlan.decide(LaunchFacts(state: keptLocal, uploadsAvailable: true, bufferReadable: true,
                                             currentNoticeVersion: "1"))
    #expect(kept.startCapture && !kept.startUploader && kept.importSink == .onDevice)
  }

  @Test("LAUNCH: a signed-in, consented person on an enrolled Mac gets capture, the uploader and the uploader-backed import sink")
  func consentedCloud() {
    for notice in ["1", nil] as [String?] {
      let plan = LaunchPlan.decide(LaunchFacts(state: M314State.sending, uploadsAvailable: true, bufferReadable: true,
                                               currentNoticeVersion: notice))
      #expect(plan == LaunchPlan(startUpdater: true, startCapture: true, startUploader: true, importSink: .uploader))
    }
  }

  @Test("LAUNCH: a changed notice keeps capture local and the uploader paused, and imports stay on the Mac")
  func noticeChanged() {
    let changed = LaunchFacts(state: M314State.sending, uploadsAvailable: true, bufferReadable: true,
                              currentNoticeVersion: "2")
    #expect(changed.reconsentPending)
    #expect(LaunchPlan.decide(changed)
            == LaunchPlan(startUpdater: true, startCapture: true, startUploader: false, importSink: .onDevice))
    // Already marked pending (screen 5 not accepted yet) and the version is not known this launch.
    var pending = M314State.sending
    pending.uploadConsent = false
    pending.reconsentPending = true
    let stillPending = LaunchPlan.decide(LaunchFacts(state: pending, uploadsAvailable: true, bufferReadable: true,
                                                     currentNoticeVersion: nil))
    #expect(!stillPending.startUploader && stillPending.startCapture && stillPending.importSink == .onDevice)
  }

  @Test("LAUNCH: an unreadable buffer starts neither capture nor the uploader")
  func unreadableBuffer() {
    let plan = LaunchPlan.decide(LaunchFacts(state: M314State.sending, uploadsAvailable: true, bufferReadable: false,
                                             currentNoticeVersion: "1"))
    #expect(plan == LaunchPlan(startUpdater: true, startCapture: false, startUploader: false, importSink: .onDevice))
  }

  @Test("LAUNCH: the backend is cloud only with an https API base, a device id and a stored device key")
  func backendMode() {
    let api = "https://api.offload.test"
    #expect(BackendMode.decide(apiBase: api, deviceID: "dev_1", deviceKeyStored: true)
            == .cloud(apiBase: URL(string: api)!, deviceID: "dev_1"))
    #expect(BackendMode.decide(apiBase: "http://127.0.0.1:8787", deviceID: "dev_1", deviceKeyStored: true)
            == .cloud(apiBase: URL(string: "http://127.0.0.1:8787")!, deviceID: "dev_1"))
    #expect(BackendMode.decide(apiBase: "http://localhost:8787", deviceID: "dev_1", deviceKeyStored: true).allowsUploads)
    #expect(BackendMode.decide(apiBase: nil, deviceID: "dev_1", deviceKeyStored: true) == .local)
    #expect(BackendMode.decide(apiBase: "", deviceID: "dev_1", deviceKeyStored: true) == .local)
    #expect(BackendMode.decide(apiBase: "http://api.offload.test", deviceID: "dev_1", deviceKeyStored: true) == .local)
    #expect(BackendMode.decide(apiBase: "ftp://api.offload.test", deviceID: "dev_1", deviceKeyStored: true) == .local)
    #expect(BackendMode.decide(apiBase: "https://", deviceID: "dev_1", deviceKeyStored: true) == .local)
    #expect(BackendMode.decide(apiBase: api, deviceID: nil, deviceKeyStored: true) == .local)
    #expect(BackendMode.decide(apiBase: api, deviceID: "  ", deviceKeyStored: true) == .local)
    #expect(BackendMode.decide(apiBase: api, deviceID: "dev_1", deviceKeyStored: false) == .local)
    #expect(!BackendMode.local.allowsUploads)
  }

  @Test("LAUNCH: the app model starts the uploader only when uploads are available")
  @MainActor func appModelUploads() {
    let fakes = M304Services()
    fakes.store.save(M314State.sending)
    let local = AppModel(options: LaunchOptions(), bundlePath: "/Applications/Offload.app", bufferReadable: true,
                         store: fakes.store, services: fakes.services, probe: FakePermissionProbe(),
                         events: NoLocalEvents(), sampleWeek: SampleWeekFlag(), currentNoticeVersion: "1",
                         uploadsAvailable: false)
    #expect(fakes.uploader.starts == 0)
    #expect(fakes.capture.starts == 1)
    #expect(!local.launchPlan.startUploader)
    let cloud = AppModel(options: LaunchOptions(), bundlePath: "/Applications/Offload.app", bufferReadable: true,
                         store: fakes.store, services: fakes.services, probe: FakePermissionProbe(),
                         events: NoLocalEvents(), sampleWeek: SampleWeekFlag(), currentNoticeVersion: "1",
                         uploadsAvailable: true)
    #expect(fakes.uploader.starts == 1)
    #expect(fakes.capture.starts == 2)
    #expect(cloud.launchPlan == LaunchPlan(startUpdater: true, startCapture: true, startUploader: true, importSink: .uploader))
  }
}
