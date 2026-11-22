import CryptoKit
import Foundation
import Testing
import OffloadContracts
import OffloadStore
import OffloadUploader

// The import half of the egress guard (ADR 0035) on PR #13's real Uploader, over a scripted transport and an encrypted
// store in a temp folder (review 1, finding 1). This file does not import OffloadMac: there `Uploader` is m3-04's
// protocol, here it is the uploader actor.

/// Answers the import routes and the batch route, records every request, and can hold the first batch request until
/// released (a flush suspended on the network).
final class ImportServer: HTTPTransport, @unchecked Sendable {
  private let lock = NSLock()
  private var log: [HTTPRequest] = []
  private var statuses: [String: [Int]] = [:]
  private var holdFirstBatch = false
  private var held = false
  let arrived: AsyncStream<Void>
  private let arrivedContinuation: AsyncStream<Void>.Continuation
  private let release: AsyncStream<Void>
  private let releaseContinuation: AsyncStream<Void>.Continuation

  init(holdFirstBatch: Bool = false) {
    self.holdFirstBatch = holdFirstBatch
    (arrived, arrivedContinuation) = AsyncStream.makeStream(of: Void.self)
    (release, releaseContinuation) = AsyncStream.makeStream(of: Void.self)
  }

  var requests: [HTTPRequest] { lock.withLock { log } }
  var batchRequests: [HTTPRequest] { requests.filter { $0.url.path == "/v1/ingest/batches" } }

  /// The next answers for one path, in order (then 200 or 201 or 202 as the route expects).
  func script(_ path: String, _ codes: [Int]) { lock.withLock { statuses[path] = codes } }

  func releaseHeldBatch() { releaseContinuation.yield() }

  func send(_ request: HTTPRequest) async throws -> HTTPResponse {
    let path = request.url.path
    let hold = lock.withLock { () -> Bool in
      guard holdFirstBatch, !held, path == "/v1/ingest/batches" else { return false }
      held = true
      return true
    }
    if hold {
      arrivedContinuation.yield()
      var it = release.makeAsyncIterator()
      _ = await it.next()
    }
    return try lock.withLock {
      log.append(request)
      if var queue = statuses[path], !queue.isEmpty {
        let code = queue.removeFirst()
        statuses[path] = queue
        if code >= 300 { return HTTPResponse(status: code, headers: [:], body: Data()) }
      }
      switch path {
      case "/v1/imports":
        return HTTPResponse(status: 201, headers: [:], body: Data("{\"import_id\":\"\(M314Uploads.importID)\"}".utf8))
      case "/v1/me/forget":
        return HTTPResponse(status: 202, headers: [:], body: Data("{\"purge_request_id\":\"p1\"}".utf8))
      case "/v1/ingest/batches":
        let json = try JSONSerialization.jsonObject(with: request.body ?? Data()) as? [String: Any] ?? [:]
        let ids = (json["objects"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
        let receipt = try JSONSerialization.data(withJSONObject: ["accepted": ids, "rejected": [Any]()], options: [.sortedKeys])
        return HTTPResponse(status: 200, headers: [:], body: receipt)
      default:
        return HTTPResponse(status: 404, headers: [:], body: Data())
      }
    }
  }
}

/// Counts token requests and forced refreshes.
final class CountingTokens: TokenProvider, @unchecked Sendable {
  private let lock = NSLock()
  private var forced = 0
  var refreshes: Int { lock.withLock { forced } }
  func token(forceRefresh: Bool) async throws -> String {
    lock.withLock { if forceRefresh { forced += 1 } }
    return "tok"
  }
}

enum M314Uploads {
  static let importID = "6f1d3c2a-8b4e-4c1f-9a2d-3e5f7a9b1c0d"
  static let apiBase = URL(string: "https://api.offload.example")!
  static let deviceID = "0193a6f2-6c1e-7b51-9d2a-5f0e8c1b2a33"
}

/// An uploader with an import outbox over one temp home (M302's TestHome: in-memory Keychain, UTC days).
final class ImportRig: @unchecked Sendable {
  let home = TestHome()
  let time = ManualTime(Date(timeIntervalSince1970: 1_794_582_000))
  let server: ImportServer
  let tokens = CountingTokens()
  let signer = SoftwareDeviceSigner()
  let ids = OffloadContracts.ULIDGenerator()
  let egress = EgressGuard(apiBase: M314Uploads.apiBase)
  let outbox: ImportOutbox
  let uploader: Uploader

  init(server: ImportServer = ImportServer()) {
    self.server = server
    outbox = ImportOutbox(layout: home.layout, keys: home.keys)
    uploader = Uploader(
      config: UploaderConfig(apiBase: M314Uploads.apiBase, deviceID: M314Uploads.deviceID), transport: server,
      signer: signer, tokens: tokens, store: home.dayStore(), state: UploadStateStore(layout: home.layout, keys: home.keys),
      ledger: EgressLedger(layout: home.layout, keys: home.keys, days: home.days), time: time, importOutbox: outbox)
  }

  var ledger: [EgressRecord] {
    (try? EgressLedger(layout: home.layout, keys: home.keys, days: home.days).read(day: home.days.day(of: time.now))) ?? []
  }

  /// Import objects of one space: a focus, a masked text snapshot, an idle start.
  func importObjects(_ importID: String = M314Uploads.importID, text: String = "Masked text only") -> [Observation] {
    let at = time.now.addingTimeInterval(-30 * 86_400)
    func id(_ s: Double) -> String { ids.next(millis: Timestamp.millis(at.addingTimeInterval(s))) }
    func ts(_ s: Double) -> String { Timestamp.format(at.addingTimeInterval(s)) }
    return [
      .focus(ObservationFocus(id: id(0), ts: ts(0), source: .import, importId: importID, appBundleId: "com.apple.Safari",
                              appName: "Safari", title: "Release notes")),
      .textSnapshot(ObservationTextSnapshot(id: id(5), ts: ts(5), source: .import, importId: importID,
                                            appBundleId: "com.apple.Safari", text: text, textHash: sha256Hex(text),
                                            textSource: .ocr)),
      .idleStart(ObservationIdleStart(id: id(130), ts: ts(130), source: .import, importId: importID)),
    ]
  }

  @discardableResult
  func addLiveFocus() throws -> Observation {
    let o = Observation.focus(ObservationFocus(id: ids.next(millis: Timestamp.millis(time.now)), ts: Timestamp.format(time.now),
                                               appBundleId: "com.apple.mail", appName: "Mail", title: "Inbox"))
    try home.dayStore().append(o)
    return o
  }

  /// Object ids in every batch the server received, in order.
  var sentIDs: [String] {
    server.batchRequests.flatMap { r -> [String] in
      let json = (try? JSONSerialization.jsonObject(with: r.body ?? Data())) as? [String: Any] ?? [:]
      return (json["objects"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
    }
  }
}

extension M314 {
  @Test("UPLOAD: opening and forgetting an import space are signed POSTs to the one host with the exact body, written to the egress ledger")
  func openAndForgetAreSignedAndLedgered() async throws {
    let rig = ImportRig()
    let id = try await rig.uploader.openImport(sourceKind: "videos")
    #expect(id == M314Uploads.importID)
    try await rig.uploader.forgetImport(id: id)

    let requests = rig.server.requests
    #expect(requests.map(\.url.absoluteString) == ["https://api.offload.example/v1/imports", "https://api.offload.example/v1/me/forget"])
    #expect(requests.allSatisfy { $0.method == "POST" && $0.headers["Authorization"] == "Bearer tok" })
    let openBody = Data(#"{"source_kind":"videos"}"#.utf8)
    let forgetBody = Data("{\"import_id\":\"\(M314Uploads.importID)\",\"scope\":\"import\"}".utf8)
    #expect(requests.map(\.body) == [openBody, forgetBody])
    // The raw r||s signature over the exact body verifies with this device's key.
    for r in requests {
      let header = try #require(r.headers["Offload-Signature"])
      #expect(header.hasPrefix("keyid=\(M314Uploads.deviceID), sig="))
      let sig = try #require(unb64url(String(header.dropFirst("keyid=\(M314Uploads.deviceID), sig=".count))))
      let key = try P256.Signing.PublicKey(x963Representation: Data([4]) + unb64url(rig.signer.publicJWK.x)! + unb64url(rig.signer.publicJWK.y)!)
      #expect(key.isValidSignature(try P256.Signing.ECDSASignature(rawRepresentation: sig), for: r.body ?? Data()))
    }
    let ledger = rig.ledger
    #expect(ledger.map(\.kind) == ["import_open", "forget"])
    #expect(ledger.map(\.destination) == ["api.offload.example", "api.offload.example"])
    #expect(ledger.map(\.body) == [openBody, forgetBody])
  }

  @Test("UPLOAD: a 401 refreshes the token once; a refused open or forget throws and writes no ledger line")
  func refusedRequests() async throws {
    let rig = ImportRig()
    rig.server.script("/v1/imports", [401])
    _ = try await rig.uploader.openImport(sourceKind: "screenshots")
    #expect(rig.tokens.refreshes == 1)
    #expect(rig.server.requests.count == 2)

    let refused = ImportRig()
    refused.server.script("/v1/imports", [403])
    await #expect(throws: ImportUploadError.rejected(status: 403)) { try await refused.uploader.openImport(sourceKind: "videos") }
    refused.server.script("/v1/me/forget", [500])
    await #expect(throws: ImportUploadError.rejected(status: 500)) { try await refused.uploader.forgetImport(id: M314Uploads.importID) }
    #expect(refused.ledger.isEmpty)
  }

  @Test("UPLOAD: the import outbox refuses live objects, objects without an import id and detector hits, and stores nothing")
  func outboxRefuses() throws {
    let rig = ImportRig()
    let live = Observation.focus(ObservationFocus(id: rig.ids.next(millis: 1_794_582_000_000), ts: "2026-11-13T15:00:00.000Z",
                                                  appBundleId: "com.apple.mail", appName: "Mail"))
    #expect(throws: ImportUploadError.notAnImportObject) { try rig.outbox.stage([live], checkedBy: rig.egress) }
    let noID = Observation.idleStart(ObservationIdleStart(id: rig.ids.next(millis: 1_794_582_000_000),
                                                          ts: "2026-11-13T15:00:00.000Z", source: .import))
    #expect(throws: ImportUploadError.notAnImportObject) { try rig.outbox.stage(rig.importObjects() + [noID], checkedBy: rig.egress) }
    // A card number that survived masking: the device detectors stop the whole hand-off.
    #expect(throws: EgressError.self) {
      try rig.outbox.stage(rig.importObjects(text: "card 4111 1111 1111 1111"), checkedBy: rig.egress)
    }
    #expect(try rig.outbox.staged().isEmpty)
  }

  @Test("UPLOAD: staged import objects are sealed on disk and sent by the next flush under the next seqs, with the live ones")
  func stagedObjectsAreSent() async throws {
    let rig = ImportRig()
    let objects = rig.importObjects()
    try rig.outbox.stage(objects, checkedBy: rig.egress)
    // Sealed: the outbox file holds no readable text.
    let raw = try Data(contentsOf: rig.outbox.file)
    #expect(raw.range(of: Data("Release notes".utf8)) == nil)
    // Another instance over the same home (a restart) sees them.
    #expect(try ImportOutbox(layout: rig.home.layout, keys: rig.home.keys).staged().map(\.id) == objects.map(\.id))

    let live = try rig.addLiveFocus()
    let report = await rig.uploader.flush()
    #expect(!report.failed)
    #expect(report.sentObjects == 4)
    #expect(Set(rig.sentIDs) == Set(objects.map(\.id) + [live.id]))
    let seqs = rig.server.batchRequests.compactMap { r -> Int? in
      ((try? JSONSerialization.jsonObject(with: r.body ?? Data())) as? [String: Any])?["seq"] as? Int
    }
    #expect(seqs == Array(1...seqs.count))
    #expect(try rig.outbox.staged().isEmpty)
    // Nothing is sent twice.
    _ = await rig.uploader.flush()
    #expect(rig.sentIDs.count == 4)
  }

  @Test("UPLOAD: an import staged while a flush waits on the network is not overwritten by the flush")
  func stagingDuringAFlush() async throws {
    let rig = ImportRig(server: ImportServer(holdFirstBatch: true))
    let live = try rig.addLiveFocus()
    let uploader = rig.uploader
    let first = Task { await uploader.flush() }
    var arrivals = rig.server.arrived.makeAsyncIterator()
    _ = await arrivals.next()
    // The flush is suspended inside its send, holding its own copy of the upload state.
    let objects = rig.importObjects()
    try rig.outbox.stage(objects, checkedBy: rig.egress)
    rig.server.releaseHeldBatch()
    let firstReport = await first.value
    #expect(firstReport.sentObjects == 1)
    #expect(rig.sentIDs == [live.id])
    #expect(try rig.outbox.staged().map(\.id) == objects.map(\.id))

    let second = await uploader.flush()
    #expect(second.sentObjects == 3)
    #expect(rig.sentIDs == [live.id] + objects.map(\.id))
    #expect(try rig.outbox.staged().isEmpty)
  }

  @Test("UPLOAD: the device key is stored only after enrollment made it, and asking never makes one")
  func deviceKeyIsStored() throws {
    let secrets = MemorySecretStore()
    #expect(!DeviceKey.isStored(secrets: secrets))
    #expect(!DeviceKey.isStored(secrets: secrets))
    #expect(try secrets.read(account: "device-key") == nil)
    #expect(try secrets.read(account: "device-key-se") == nil)
    _ = try DeviceKey.loadOrCreate(secrets: secrets, preferSecureEnclave: false)
    #expect(DeviceKey.isStored(secrets: secrets))
  }
}
