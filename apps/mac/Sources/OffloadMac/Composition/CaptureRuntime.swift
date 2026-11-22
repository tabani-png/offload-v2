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

  /// The encrypted buffer, shared with the uploader (one key ring, one day store).
  public let context: StoreContext
  /// The one Never watch list (the same store the screens, the menu bar and the import use).
  public let neverWatch: any ExclusionSource
  /// The day store, set on the first start. The local now line reads it through `events`.
  public let store: StoreHandle
  public let events: StoreEventSource
  /// Why the last start failed (the error's type, never its text), or nil.
  public private(set) var lastError: String?

  private let ticks: Bool
  private var observer: Observer?
  private var pause: LivePauseSource?
  private var exclusions: ExclusionsFile?
  private var timer: Timer?
  private var running = false
  private var ticking = false

  /// `ticks: false` builds and starts everything but never ticks the observer (tests: no TCC, no live reads).
  public init(context: StoreContext, neverWatch: any ExclusionSource, ticks: Bool = true) {
    self.context = context
    self.neverWatch = neverWatch
    self.ticks = ticks
    let handle = StoreHandle()
    store = handle
    events = StoreEventSource(handle: handle)
  }

  /// Capture over its own store context (tests, tools).
  public convenience init(home: URL = StoreLayout.defaultHome(), neverWatch: any ExclusionSource, secrets: any SecretStore,
                          ticks: Bool = true) {
    self.init(context: StoreContext(home: home, secrets: secrets), neverWatch: neverWatch, ticks: ticks)
  }

  public var home: URL { context.home }

  /// True only while capture really runs; the menu bar and screen 13 say "not watching" otherwise.
  public var isRunning: Bool { running }

  public var exclusionsFile: URL { context.layout.exclusionsFile }

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

  /// m3-03: Sparkle is about to install an update. The composition's UpdatePreparation also pauses the uploader.
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
    let secrets = context.secrets
    return ImportMaskerAdapter(load: { try CaptureRuntime.masker(secrets: secrets) })
  }

  /// Creates the pseudonym key on the first capture if none exists, before any enrollment (a recorded divergence from
  /// SECURITY_PRIVACY section 6; see PseudonymKeyStore and the SPEC's Scope changes, review 3).
  nonisolated static func masker(secrets: any SecretStore) throws -> TextMasker {
    TextMasker(pseudonymizer: Pseudonymizer(key: try PseudonymKeyStore(secrets: secrets).loadOrCreate()))
  }

  private func build() throws {
    let layout = context.layout
    try layout.ensureDirectories()
    let days = context.days
    let keys = context.keys
    let dayStore = context.dayStore
    let time = SystemTime()
    let masker = try Self.masker(secrets: context.secrets)
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

  /// What one tick runs on the observer. Tests replace it to see the order without running the live sources.
  var observerTick: @MainActor (Observer) async -> Void = { await $0.tick() }

  /// One tick, only while capture runs: the Never watch list is written first, so an entry added since the last tick
  /// applies to this one, then the observer runs, unless a tick is still running. False when nothing ticked.
  @discardableResult
  public func tickOnce() async -> Bool {
    guard running, let observer, !ticking else { return false }
    _ = try? syncExclusions()
    ticking = true
    await observerTick(observer)
    ticking = false
    return true
  }

  private func schedule() {
    timer?.invalidate()
    // Added in the common run-loop modes, so capture keeps ticking while a menu is open (review 1, finding 7).
    let timer = Timer(timeInterval: Self.tickInterval, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self, !self.ticking else { return }
        Task { @MainActor in await self.tickOnce() }
      }
    }
    RunLoop.main.add(timer, forMode: .common)
    self.timer = timer
  }
}
