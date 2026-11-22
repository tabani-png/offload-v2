// The uploader side of PR #13's CaptureRuntime (slice m3-14-mac-app-integration). It exists only when this Mac is
// enrolled (`BackendMode.cloud`), and it is started only when LaunchPlan or onboarding's "Start sending" says so;
// `pause()` (a changed notice, row 11.11) stops its turns. PR #13's Uploader is built on the first turn, not before.
// It is also the import's way out (ImportUploadQueue): opening an import space, queueing its objects and forgetting it
// all go through the same uploader, egress guard and ledger (ADR 0035).
import Foundation
import OffloadContracts
import OffloadStore
import OffloadUploader

@MainActor public final class UploadRuntime: Uploader {
  /// The app offers the uploader a turn this often; it sends every 300 s itself (UploaderConfig.flushSeconds).
  public static let turnInterval: TimeInterval = 30

  public let apiBase: URL
  public let deviceID: String
  public let home: URL
  /// Why building the uploader failed (the error's type, never its text), or nil.
  public private(set) var lastError: String?

  private let secrets: any SecretStore
  private let turns: Bool
  private var built: OffloadUploader.Uploader?
  private var timer: Timer?
  private var running = false

  /// `turns: false` never schedules a turn (tests: nothing is built, nothing is sent).
  public init(apiBase: URL, deviceID: String, home: URL, secrets: any SecretStore, turns: Bool = true) {
    self.apiBase = apiBase
    self.deviceID = deviceID
    self.home = home
    self.secrets = secrets
    self.turns = turns
  }

  public var isRunning: Bool { running }

  public func start() {
    guard !running else { return }
    running = true
    if turns { schedule() }
  }

  public func pause() {
    timer?.invalidate()
    timer = nil
    running = false
  }

  /// PR #13's uploader over the encrypted store under `home`: the device key, the device session, the one API host.
  public func uploader() throws -> OffloadUploader.Uploader {
    if let built { return built }
    let layout = StoreLayout(home: home)
    try layout.ensureDirectories()
    let days = DayCalendar()
    let keys = KeyRing(layout: layout, secrets: secrets)
    let time = SystemTime()
    let signer = try DeviceKey.loadOrCreate(secrets: secrets).signer
    let transport = URLSessionTransport()
    let guarded = GuardedTransport(inner: transport, guard: EgressGuard(apiBase: apiBase))
    let session = DeviceSession(apiBase: apiBase, deviceID: deviceID, signer: signer, transport: guarded, time: time)
    let made = OffloadUploader.Uploader(
      config: UploaderConfig(apiBase: apiBase, deviceID: deviceID), transport: transport, signer: signer,
      tokens: session, store: DayStore(layout: layout, keys: keys, days: days),
      state: UploadStateStore(layout: layout, keys: keys), ledger: EgressLedger(layout: layout, keys: keys, days: days),
      time: time)
    built = made
    return made
  }

  /// Sends what is pending now. Not called on quit yet (the queue is on disk, so the next launch sends it).
  public func flush() async {
    guard running, let uploader = try? uploader() else { return }
    _ = await uploader.flush()
  }

  private func schedule() {
    timer?.invalidate()
    timer = Timer.scheduledTimer(withTimeInterval: Self.turnInterval, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self, self.running else { return }
        do {
          let uploader = try self.uploader()
          Task { _ = await uploader.tick() }
        } catch {
          self.lastError = String(describing: type(of: error))
        }
      }
    }
  }
}

extension UploadRuntime: ImportUploadQueue {
  /// Refused while paused (no consent on record, or a new notice waits): nothing leaves then.
  public func openImport(sourceKind: String) async throws -> String {
    guard running else { throw ImportUploadRefusal(reason: "uploads are paused") }
    return try await uploader().openImport(sourceKind: sourceKind)
  }

  public func enqueueImport(_ objects: [Observation]) async throws -> Int {
    guard running else { throw ImportUploadRefusal(reason: "uploads are paused") }
    return try await uploader().enqueueImport(objects)
  }

  public func forgetImport(id: String) async throws {
    try await uploader().forgetImport(id: id)
  }
}
