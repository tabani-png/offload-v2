import Foundation
import Testing
@testable import OffloadMac

// m3-04-mac-onboarding (slices/m3-04-mac-onboarding/SPEC.md). Every test of this slice is a member of M304; the
// tests live in extensions of it, one file per area. Nothing here touches TCC, the network, a window or a model.

@Suite struct M304 {}

/// Paths and file reads relative to apps/mac, from this file (apps/mac/Tests/OffloadMacTests/M304/M304.swift).
enum M304Repo {
  static let macRoot: URL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()  // M304
    .deletingLastPathComponent()  // OffloadMacTests
    .deletingLastPathComponent()  // Tests
    .deletingLastPathComponent()  // apps/mac

  /// Every .swift file under a folder of apps/mac, with its text.
  static func swiftSources(_ relative: String) -> [(path: String, text: String)] {
    let dir = macRoot.appendingPathComponent(relative, isDirectory: true)
    guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil) else { return [] }
    var out: [(path: String, text: String)] = []
    for case let url as URL in e where url.pathExtension == "swift" {
      let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
      out.append((path: url.path, text: text))
    }
    return out
  }

  static func words(_ s: String) -> Int {
    s.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\u{00A0}" }).count
  }
}

/// A fixed clock: Wed 11 Nov 2026 15:00 UTC (the old s34 NOW).
enum M304Clock {
  static let nowMs: Int64 = 1_794_582_000_000
  static let now = Date(timeIntervalSince1970: TimeInterval(nowMs) / 1000)
  static let minute: Int64 = 60_000
}

// MARK: - Fakes

@MainActor final class FakePermissionProbe: PermissionProbe {
  var accessibility = false
  var preflight = false
  var macOSMajor = 15
  private(set) var accessibilityPrompts = 0
  private(set) var screenCaptureRequests = 0
  private(set) var opened: [URL] = []
  private(set) var finderReveals = 0
  private(set) var calls: [String] = []

  func isAccessibilityTrusted() -> Bool { calls.append("isAccessibilityTrusted"); return accessibility }
  func screenCapturePreflight() -> Bool { calls.append("screenCapturePreflight"); return preflight }
  func promptAccessibility() { calls.append("promptAccessibility"); accessibilityPrompts += 1 }
  func requestScreenCapture() { calls.append("requestScreenCapture"); screenCaptureRequests += 1 }
  func openSettings(_ url: URL) { calls.append("openSettings"); opened.append(url) }
  func revealAppInFinder() { calls.append("revealAppInFinder"); finderReveals += 1 }
}

@MainActor final class FakeAccount: AccountService {
  var result: SignInResult = .signedIn
  private(set) var calls = 0
  func signIn() async -> SignInResult { calls += 1; return result }
}

@MainActor final class FakeConsent: ConsentService {
  private(set) var recorded: [String] = []
  func recordUploadConsent(noticeVersion: String) async throws { recorded.append(noticeVersion) }
}

@MainActor final class FakeUploader: Uploader {
  private(set) var starts = 0
  func start() { starts += 1 }
}

@MainActor final class FakeCapture: CaptureControl {
  private(set) var starts = 0
  func start() { starts += 1 }
}

@MainActor final class FakeProfile: ProfileService {
  private(set) var patches: [ProfileUpdate] = []
  func patch(_ update: ProfileUpdate) async throws { patches.append(update) }
}

/// Records whether the local store already held the entries when the server call started.
@MainActor final class FakeExclusionService: ExclusionService {
  let store: NeverWatchStore
  private(set) var uploads: [[Exclusion]] = []
  private(set) var localHadThemFirst: [Bool] = []
  init(store: NeverWatchStore) { self.store = store }
  func upload(_ exclusions: [Exclusion]) async throws {
    let local = Set(store.currentExclusions())
    localHadThemFirst.append(exclusions.allSatisfy { local.contains($0) })
    uploads.append(exclusions)
  }
}

@MainActor final class FakeConnections: ConnectionService {
  var next: ConnectResult = .connected(account: "sample account")
  private(set) var asked: [String] = []
  func connect(appID: String) async -> ConnectResult { asked.append(appID); return next }
}

@MainActor final class FakeLoginItem: LoginItemService {
  private(set) var set: [Bool] = []
  func setEnabled(_ on: Bool) { set.append(on) }
}

@MainActor final class FakeRelauncher: Relauncher {
  private(set) var relaunches = 0
  func relaunch() { relaunches += 1 }
}

@MainActor final class FakeSampleWeek: SampleWeekPresenter {
  private(set) var shown = 0
  func show() { shown += 1 }
}

@MainActor struct M304Services {
  let store = InMemoryOnboardingStore()
  let account = FakeAccount()
  let consent = FakeConsent()
  let uploader = FakeUploader()
  let capture = FakeCapture()
  let profile = FakeProfile()
  let neverWatch = NeverWatchStore()
  let exclusions: FakeExclusionService
  let connections = FakeConnections()
  let loginItem = FakeLoginItem()
  let relauncher = FakeRelauncher()
  let sampleWeek = FakeSampleWeek()

  init() { exclusions = FakeExclusionService(store: neverWatch) }

  var services: OnboardingServices {
    OnboardingServices(
      account: account, consent: consent, uploader: uploader, capture: capture, profile: profile,
      neverWatch: neverWatch, exclusions: exclusions, connections: connections, loginItem: loginItem,
      relauncher: relauncher, sampleWeek: sampleWeek
    )
  }

  func model() -> OnboardingModel { OnboardingModel(store: store, services: services) }
}

// MARK: - Flow helpers

extension OnboardingFlow {
  /// Performs actions in order and returns every effect they produced.
  @discardableResult
  mutating func run(_ actions: [OnboardingAction], now: Date = M304Clock.now) -> [OnboardingEffect] {
    var all: [OnboardingEffect] = []
    for a in actions { all += perform(a, now: now) }
    return all
  }
}

enum M304Path {
  /// From screen 0 to screen 5 with both permissions on and signed in.
  static let toWhatLeaves: [OnboardingAction] = [
    .next,                                                        // 0 → 1
    .next,                                                        // 1 → 2
    .permissionsRead(accessibility: true, screenRecording: true),
    .next,                                                        // 2 → 3
    .next,                                                        // 3 → 4
    .signInResult(.signedIn),                                     // 4 → 5
  ]
}
