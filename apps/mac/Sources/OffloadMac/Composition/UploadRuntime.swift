// The uploader side of PR #13's CaptureRuntime (slice m3-14-mac-app-integration). It exists only when this Mac is
// enrolled (`UploadBackend.cloud`), and it runs only when LaunchPlan or onboarding's "Start sending" says so; `pause()`
// (a changed notice, row 11.11, or an update) stops its turns. PR #13's Uploader is built on the first turn, over the
// composition's one StoreContext. It is also the recordings import's only way out (ImportUploadQueue): opening an
// import space, staging its objects and forgetting it all go through this runtime, the egress guard and the ledger
// (ADR 0035). Opening and staging are refused while uploads are paused; forgetting (a delete request) is not.
import Foundation
import OffloadContracts
import OffloadStore
import OffloadUploader

/// Whether uploads may run, readable off the main actor (the import's sink stages from the importer's task).
final class UploadGate: @unchecked Sendable {
  private let lock = NSLock()
  private var isOpen = false
  var open: Bool {
    get { lock.withLock { isOpen } }
    set { lock.withLock { isOpen = newValue } }
  }
}

@MainActor public final class UploadRuntime: Uploader {
  /// The app offers the uploader a turn this often; it sends every 300 s itself (UploaderConfig.flushSeconds).
  public static let turnInterval: TimeInterval = 30

  /// The way out: the one transport and how a token session is made for an audience. `.live` is URLSession and PR #13's
  /// DeviceSession; tests pass a scripted transport and fixed tokens.
  public struct Network: Sendable {
    public var transport: any OffloadUploader.HTTPTransport
    public var session: @Sendable (_ apiBase: URL, _ deviceID: String, _ signer: any DeviceSigner,
                                   _ transport: any OffloadUploader.HTTPTransport, _ audience: TokenAudience) -> any TokenProvider

    public init(transport: any OffloadUploader.HTTPTransport,
                session: @escaping @Sendable (URL, String, any DeviceSigner, any OffloadUploader.HTTPTransport, TokenAudience) -> any TokenProvider) {
      self.transport = transport
      self.session = session
    }

    public static var live: Network {
      Network(transport: OffloadUploader.URLSessionTransport(), session: { apiBase, deviceID, signer, transport, audience in
        DeviceSession(apiBase: apiBase, deviceID: deviceID, signer: signer, transport: transport, time: SystemTime(),
                      audience: audience)
      })
    }
  }

  public let apiBase: URL
  public let deviceID: String
  public let context: StoreContext
  /// Where import objects wait, sealed on this Mac, for the next flush.
  public nonisolated let outbox: ImportOutbox
  /// Why building the uploader failed (the error's type, never its text), or nil.
  public private(set) var lastError: String?

  private nonisolated let egress: EgressGuard
  private nonisolated let gate = UploadGate()
  private let turns: Bool
  private let network: Network
  private var built: OffloadUploader.Uploader?
  private var timer: Timer?

  /// `turns: false` never schedules a turn (tests: nothing is built, nothing is sent).
  public init(apiBase: URL, deviceID: String, context: StoreContext, turns: Bool = true, network: Network = .live) {
    self.network = network
    self.apiBase = apiBase
    self.deviceID = deviceID
    self.context = context
    self.turns = turns
    outbox = context.importOutbox
    egress = EgressGuard(apiBase: apiBase)
  }

  public var isRunning: Bool { gate.open }

  public func start() {
    guard !gate.open else { return }
    gate.open = true
    if turns { schedule() }
  }

  public func pause() {
    timer?.invalidate()
    timer = nil
    gate.open = false
  }

  /// PR #13's uploader over the shared store and the shared import outbox: the device key, one token session per
  /// audience (`device` for ingest, `member` for the import space routes), the one API host.
  public func uploader() throws -> OffloadUploader.Uploader {
    if let built { return built }
    try context.layout.ensureDirectories()
    let signer = try DeviceKey.loadOrCreate(secrets: context.secrets).signer
    let transport = network.transport
    let guarded = GuardedTransport(inner: transport, guard: egress)
    let made = OffloadUploader.Uploader(
      config: UploaderConfig(apiBase: apiBase, deviceID: deviceID), transport: transport, signer: signer,
      tokens: network.session(apiBase, deviceID, signer, guarded, .device), store: context.dayStore,
      state: UploadStateStore(layout: context.layout, keys: context.keys),
      ledger: EgressLedger(layout: context.layout, keys: context.keys, days: context.days), time: SystemTime(),
      importOutbox: outbox, memberTokens: network.session(apiBase, deviceID, signer, guarded, .member))
    built = made
    return made
  }

  private func schedule() {
    timer?.invalidate()
    // Common run-loop modes: turns keep coming while a menu is open (review 1, finding 7).
    let timer = Timer(timeInterval: Self.turnInterval, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self, self.gate.open else { return }
        do {
          let uploader = try self.uploader()
          Task { _ = await uploader.tick() }
        } catch {
          self.lastError = String(describing: type(of: error))
        }
      }
    }
    RunLoop.main.add(timer, forMode: .common)
    self.timer = timer
  }
}

extension UploadRuntime: ImportUploadQueue {
  public func openImport(sourceKind: String) async throws -> String {
    guard gate.open else { throw ImportUploadRefusal(reason: "uploads are paused") }
    return try await uploader().openImport(sourceKind: sourceKind)
  }

  /// On this Mac only: checked and sealed in the outbox before it returns; sent by the uploader's next flush.
  public nonisolated func stageImport(_ objects: [Observation]) throws {
    guard gate.open else { throw ImportUploadRefusal(reason: "uploads are paused") }
    try outbox.stage(objects, checkedBy: egress)
  }

  /// Allowed while paused: it asks the server to delete, it sends no observation.
  public func forgetImport(id: String) async throws {
    try await uploader().forgetImport(id: id)
  }
}
