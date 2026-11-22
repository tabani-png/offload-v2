// Live capture (slice m3-02's CaptureRuntime, split by m3-14-mac-app-integration). It wires PR #13's live sources to
// the observer, the masker and the encrypted 7-day day store, and ticks the observer once a second. The observer runs
// inside the app process (a child of the app for TCC attribution, spike S1).
//
// Consent: nothing is built, created on disk or written to the Keychain until `start()`, which the app calls only
// when LaunchPlan allows it (screen 2 resolved) or when onboarding resolves screen 2. Capture is local: it needs no
// API base or device, and it never sends. Uploading is UploadRuntime's, which exists only for an enrolled Mac.
import Foundation
import OffloadContracts
import OffloadMasker
import OffloadObserver
import OffloadStore
import OffloadUploader

@MainActor public final class CaptureRuntime: CaptureControl, CaptureLifecycle {
  public static let tickInterval: TimeInterval = 1

  public let home: URL
  /// The one Never watch list (the same store the screens, the menu bar and the import use).
  public let neverWatch: any ExclusionSource
  /// The day store, set on the first start. The local now line reads it through `events`.
  public let store: StoreHandle
  public let events: StoreEventSource
  /// Why the last start failed (the error's type, never its text), or nil.
  public private(set) var lastError: String?

  private let secrets: any SecretStore
  private let ticks: Bool
  private var observer: Observer?
  private var pause: LivePauseSource?
  private var exclusions: ExclusionsFile?
  private var timer: Timer?
  private var running = false
  private var ticking = false

  /// `ticks: false` builds and starts everything but never ticks the observer (tests: no TCC, no live reads).
  public init(home: URL = StoreLayout.defaultHome(), neverWatch: any ExclusionSource, secrets: any SecretStore,
              ticks: Bool = true) {
    self.home = home
    self.neverWatch = neverWatch
    self.secrets = secrets
    self.ticks = ticks
    let handle = StoreHandle()
    store = handle
    events = StoreEventSource(handle: handle)
  }

  /// True only while capture really runs; the menu bar and screen 13 say "not watching" otherwise.
  public var isRunning: Bool { running }

  public var exclusionsFile: URL { StoreLayout(home: home).exclusionsFile }

  public func start() {
    guard !running else { return }
    do {
      if observer == nil { try build() }
      try syncExclusions()
      running = true
      lastError = nil
      if ticks { schedule() }
    } catch {
      lastError = String(describing: type(of: error))
    }
  }

  /// Stops ticking. The day store stays open for the local now line.
  public func stop() {
    timer?.invalidate()
    timer = nil
    running = false
  }

  /// m3-03: Sparkle is about to install an update. The upload queue is on disk, so stopping loses nothing.
  func prepareForUpdate() { stop() }

  /// Writes the Never watch list to the observer's exclusions file when it changed. True when written.
  @discardableResult
  public func syncExclusions() throws -> Bool {
    let file = exclusions ?? ExclusionsFile(file: exclusionsFile, source: neverWatch)
    exclusions = file
    return try file.sync()
  }

  /// The masker for recordings imports: the same pseudonym key as live capture, loaded when the first text is masked.
  public func importMasker() -> ImportMaskerAdapter {
    let secrets = self.secrets
    return ImportMaskerAdapter(load: { try CaptureRuntime.masker(secrets: secrets) })
  }

  nonisolated static func masker(secrets: any SecretStore) throws -> TextMasker {
    TextMasker(pseudonymizer: Pseudonymizer(key: try PseudonymKeyStore(secrets: secrets).loadOrCreate()))
  }

  private func build() throws {
    let layout = StoreLayout(home: home)
    try layout.ensureDirectories()
    let days = DayCalendar()
    let keys = KeyRing(layout: layout, secrets: secrets)
    let dayStore = DayStore(layout: layout, keys: keys, days: days)
    let time = SystemTime()
    let masker = try Self.masker(secrets: secrets)
    let reveals = RevealMap(layout: layout, keys: keys, days: days)
    let pause = LivePauseSource()
    observer = Observer(
      time: time, days: days, workspace: LiveWorkspace(), idle: LiveIdle(), power: LivePower(),
      permissions: LivePermissions(), pause: pause, ax: LiveAXText(), ocr: LiveOCR(),
      exclusions: ExclusionReloader(file: layout.exclusionsFile, time: time), masker: masker, sink: dayStore,
      reveals: reveals, retention: Retention(layout: layout, days: days))
    self.pause = pause
    store.set(dayStore)
  }

  private func schedule() {
    timer?.invalidate()
    timer = Timer.scheduledTimer(withTimeInterval: Self.tickInterval, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self, !self.ticking, let observer = self.observer else { return }
        // Never watch first, so an entry added since the last tick applies to this one.
        _ = try? self.syncExclusions()
        self.ticking = true
        Task { @MainActor in
          await observer.tick()
          self.ticking = false
        }
      }
    }
  }
}
