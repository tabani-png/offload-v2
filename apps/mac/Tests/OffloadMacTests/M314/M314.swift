import Foundation
import Testing
@testable import OffloadMac
import OffloadContracts
import OffloadImport
import OffloadStore

// m3-14-mac-app-integration (slices/m3-14-mac-app-integration/SPEC.md). Every test of this slice is a member of M314;
// the tests live in extensions of it, one file per area. Nothing here touches TCC, the Keychain, the network, Sparkle,
// a window or a model: secrets are in memory, homes are temp folders, capture never ticks.
//
// Names: this test module also holds M302 (which imports OffloadUploader, whose `Uploader` actor shares its name with
// m3-04's `Uploader` protocol) and OffloadImport has its own `ULIDGenerator`, so both are always module-qualified here.

@Suite struct M314 {}

enum M314Fixture {
  /// A temp folder that does not exist yet.
  static func tempHome() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("m314-\(UUID().uuidString)", isDirectory: true)
  }

  static let apiBase = URL(string: "https://api.offload.test")!
  static let cloud = BackendMode.cloud(apiBase: apiBase, deviceID: "dev_m314")

  /// Fri 13 Nov 2026 15:00 UTC.
  static let t0 = Date(timeIntervalSince1970: 1_794_582_000)
  static let utc = TimeZone(identifier: "UTC")!

  /// Import space ids are UUIDs in the contract (`import_id`), as the server returns them.
  static let importID = "6f1d3c2a-8b4e-4c1f-9a2d-3e5f7a9b1c0d"
  static let otherImportID = "2b7e9f14-5c3a-4d8e-b1f6-0a4c8e2d6f93"

  static func ms(_ date: Date) -> Int64 { Timestamp.millis(date) }

  /// Contract ULIDs, increasing with time.
  static let ids = OffloadContracts.ULIDGenerator()
  static func id(_ date: Date) -> String { ids.next(millis: Timestamp.millis(date)) }

  /// Every .swift file under a folder of apps/mac, with its path relative to apps/mac and its text.
  static func swiftSources(_ relative: String) -> [(path: String, text: String)] {
    M304Repo.swiftSources(relative).map { f in
      let root = M304Repo.macRoot.path + "/"
      return (path: f.path.hasPrefix(root) ? String(f.path.dropFirst(root.count)) : f.path, text: f.text)
    }
  }
}

/// Saved onboarding states at the points the launch decisions care about.
enum M314State {
  /// Nothing answered yet.
  static var fresh: OnboardingState { OnboardingState() }

  /// Screen 2 resolved with Accessibility on: capture consented, Local mode.
  static var watchingLocally: OnboardingState {
    var s = OnboardingState()
    s.screen = .lastTenMinutes
    s.history = [.install, .whatItWatches, .permissions]
    s.accessibility = true
    s.captureStarted = true
    return s
  }

  /// Signed in, "Start sending" accepted on notice version 1, setup done.
  static var sending: OnboardingState {
    var s = watchingLocally
    s.signedIn = true
    s.uploadConsent = true
    s.consentedNoticeVersion = "1"
    s.completed = true
    s.setupCompletedAt = M314Fixture.t0
    s.screen = .done
    return s
  }
}

/// The uploader side of an import, recorded.
actor FakeImportQueue: ImportUploadQueue {
  private(set) var opened: [String] = []
  private(set) var queued: [[Observation]] = []
  private(set) var forgotten: [String] = []
  let importID: String

  init(importID: String = M314Fixture.importID) { self.importID = importID }

  func openImport(sourceKind: String) async throws -> String {
    opened.append(sourceKind)
    return importID
  }

  func enqueueImport(_ objects: [Observation]) async throws -> Int {
    queued.append(objects)
    return objects.count
  }

  func forgetImport(id: String) async throws { forgotten.append(id) }
}

/// Reads no text. Stands in for m3-10's on-device OCR.
struct M314Recognizer: TextRecognizer {
  func recognize(_ frame: ImportFrame) throws -> [OCRLine] { [] }
}

/// A sink that keeps nothing. Stands in for m3-10's local analysis store.
final class M314LocalSink: ImportSink, @unchecked Sendable {
  func openImport(sourceKind: ImportSourceKind) async throws -> ImportSpace { ImportSpace(id: "local", sourceKind: sourceKind) }
  func write(_ observations: [ImportObservation], to space: ImportSpace) throws {}
  func forget(_ space: ImportSpace) async throws {}
}

/// What the composition handed to the recordings model and the updater.
@MainActor final class M314Wiring {
  var importer: RecordingImporter?
  var sink: (any ImportSink)?
  var neverWatch: NeverWatchStore?
  var recordingsBuilt = 0
  var captureForUpdates: (any CaptureLifecycle)?
}

@MainActor enum M314App {
  /// The composition root over fakes: no NSApp, TCC, Keychain, Sparkle or window, and capture never ticks.
  static func composition(
    backend: BackendMode = .local, state: OnboardingState? = nil, currentNoticeVersion: String? = nil,
    bufferReadable: Bool = true, probe: FakePermissionProbe = FakePermissionProbe(),
    seams: CompositionSeams = CompositionSeams(), home: URL = M314Fixture.tempHome(),
    secrets: MemorySecretStore = MemorySecretStore(), wiring: M314Wiring = M314Wiring()
  ) -> AppComposition {
    let env = CompositionEnvironment(
      backend: backend, home: home, secrets: secrets, onboardingStore: InMemoryOnboardingStore(state: state),
      probe: probe, options: LaunchOptions(), bundlePath: "/Applications/Offload.app", bufferReadable: bufferReadable,
      currentNoticeVersion: currentNoticeVersion, loginItem: FakeLoginItem(), relauncher: FakeRelauncher(),
      account: FakeAccount(), consent: FakeConsent(), timers: false
    )
    return AppComposition(
      environment: env, seams: seams,
      recordings: { importer, sink, _, neverWatch in
        wiring.importer = importer
        wiring.sink = sink
        wiring.neverWatch = neverWatch
        wiring.recordingsBuilt += 1
        return nil
      },
      updates: { capture in
        wiring.captureForUpdates = capture
        return nil
      }
    )
  }
}
