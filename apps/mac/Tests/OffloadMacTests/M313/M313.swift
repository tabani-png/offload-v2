import Foundation
import Testing
@testable import OffloadMac

// m3-13-mac-build-progress (slices/m3-13-mac-build-progress/SPEC.md). Every test of this slice is a member of M313;
// the tests live in extensions of it, one file per area. Build JSON follows the build-loop port's `buildView`
// (port/build-loop services/builder/src/http.ts and loop.ts: stages teeth_gate, worker, verification, fan_out,
// winner). The builds client, the signer, the sleeper and the clock are fakes; HTTP tests use m3-10's
// RecordingTransport. Nothing touches the network, a window, the Keychain or a model.

@Suite struct M313 {}

/// A clock the tests move.
final class M313Now: @unchecked Sendable {
  private let lock = NSLock()
  private var current: Date

  init(_ date: Date = M313F.date("2026-11-22T12:00:00Z")) { current = date }

  var date: Date {
    lock.lock()
    defer { lock.unlock() }
    return current
  }

  func advance(_ seconds: Double) {
    lock.lock()
    defer { lock.unlock() }
    current = current.addingTimeInterval(seconds)
  }
}

/// Records every delay it is asked to wait; never waits. The `limit`-th call throws, which ends a loop.
final class M313Sleeper: BuildSleeper, @unchecked Sendable {
  struct Stop: Error {}
  private let lock = NSLock()
  private var seen: [Double] = []
  let limit: Int

  init(limit: Int = 500) { self.limit = limit }

  func sleep(seconds: Double) async throws {
    if record(seconds) >= limit { throw Stop() }
  }

  private func record(_ s: Double) -> Int {
    lock.lock()
    defer { lock.unlock() }
    seen.append(s)
    return seen.count
  }

  var delays: [Double] {
    lock.lock()
    defer { lock.unlock() }
    return seen
  }
}

/// Records the bodies it signs and returns a fixed header value.
final class M313Signer: RequestSigner, @unchecked Sendable {
  static let header = "keyid=0193a6f2-6c1e-7b51-9d2a-5f0e8c1b2a99, sig=AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8"
  private let lock = NSLock()
  private var seen: [Data] = []

  func signature(for body: Data) throws -> String {
    lock.lock()
    defer { lock.unlock() }
    seen.append(body)
    return Self.header
  }

  var bodies: [Data] {
    lock.lock()
    defer { lock.unlock() }
    return seen
  }
}

struct M313Token: MemberTokenProvider {
  func currentToken() -> String? { "m313-member-token-Q8wLx2" }
}

/// Holds the first `parks` calls that reach it until `open()`, so a test can change the screen while a request is in
/// flight. Later calls pass straight through.
final class M313Gate: @unchecked Sendable {
  private let lock = NSLock()
  private var opened = false
  private var parked: [CheckedContinuation<Void, Never>] = []
  private var count = 0
  private let parks: Int

  init(parks: Int = 1) { self.parks = parks }

  func wait() async {
    await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
      if !park(c) { c.resume() }
    }
  }

  private func park(_ c: CheckedContinuation<Void, Never>) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    count += 1
    guard !opened, count <= parks else { return false }
    parked.append(c)
    return true
  }

  func open() {
    for c in release() { c.resume() }
  }

  private func release() -> [CheckedContinuation<Void, Never>] {
    lock.lock()
    defer { lock.unlock() }
    opened = true
    let p = parked
    parked = []
    return p
  }

  var arrived: Int {
    lock.lock()
    defer { lock.unlock() }
    return count
  }

  /// Yields until `n` calls have reached the gate.
  func arrival(_ n: Int = 1) async {
    var spins = 0
    while arrived < n && spins < 200_000 {
      spins += 1
      await Task.yield()
    }
  }
}

/// A scripted BuildsClient: each method answers from its queue in order, then from its fallback; an unscripted call
/// fails with `badResponse(599)`. Every call is logged as "<method> <id> …".
final class M313Client: BuildsClient, @unchecked Sendable {
  enum Reply: @unchecked Sendable {
    case value(Any)
    case error(APIError)
  }

  private let lock = NSLock()
  private var queues: [String: [Reply]] = [:]
  private var fallbacks: [String: Reply] = [:]
  private var log: [String] = []
  private var okHashes: [FixHashes] = []
  private var deployed: [DeployHashes] = []
  private let gate: M313Gate?
  private let gated: Set<String>

  /// Calls to the `gated` methods wait at `gate` after they are logged and before they answer.
  init(gate: M313Gate? = nil, gated: Set<String> = []) {
    self.gate = gate
    self.gated = gated
  }

  private func hold(_ method: String) async {
    if gated.contains(method), let gate { await gate.wait() }
  }

  func script(_ method: String, _ replies: Reply...) {
    lock.lock()
    defer { lock.unlock() }
    queues[method, default: []].append(contentsOf: replies)
  }

  func fallback(_ method: String, _ reply: Reply) {
    lock.lock()
    defer { lock.unlock() }
    fallbacks[method] = reply
  }

  var calls: [String] {
    lock.lock()
    defer { lock.unlock() }
    return log
  }

  func count(_ prefix: String) -> Int { calls.filter { $0.hasPrefix(prefix) }.count }

  var okBuildHashes: [FixHashes] {
    lock.lock()
    defer { lock.unlock() }
    return okHashes
  }

  var deployHashes: [DeployHashes] {
    lock.lock()
    defer { lock.unlock() }
    return deployed
  }

  private func take(_ method: String, _ entry: String, ok: FixHashes? = nil, deploy: DeployHashes? = nil) -> Reply {
    lock.lock()
    defer { lock.unlock() }
    log.append(entry)
    if let ok { okHashes.append(ok) }
    if let deploy { deployed.append(deploy) }
    if var q = queues[method], !q.isEmpty {
      let r = q.removeFirst()
      queues[method] = q
      return r
    }
    return fallbacks[method] ?? .error(.badResponse(status: 599))
  }

  private func answer<T>(_ reply: Reply) throws -> T {
    switch reply {
    case .value(let v): return v as! T
    case .error(let e): throw e
    }
  }

  func openOpportunities() async throws -> [Opportunity] {
    let r = take("openOpportunities", "openOpportunities")
    await hold("openOpportunities")
    return try answer(r)
  }
  func opportunity(id: String) async throws -> Opportunity {
    let r = take("opportunity", "opportunity \(id)")
    await hold("opportunity")
    return try answer(r)
  }
  func answerOpportunity(id: String, answer a: OpportunityAnswer, optionID: String?) async throws -> Opportunity {
    let r = take("answer", "answer \(id) \(a.rawValue) \(optionID ?? "-")")
    await hold("answer")
    return try answer(r)
  }
  func fix(id: String) async throws -> Fix {
    let r = take("fix", "fix \(id)")
    await hold("fix")
    return try answer(r)
  }
  func okBuild(fixID: String, hashes: FixHashes) async throws -> BuildStarted {
    let r = take("okBuild", "okBuild \(fixID)", ok: hashes)
    await hold("okBuild")
    return try answer(r)
  }
  func build(id: String) async throws -> Build {
    let r = take("build", "build \(id)")
    await hold("build")
    return try answer(r)
  }
  func cancel(id: String) async throws -> Build {
    let r = take("cancel", "cancel \(id)")
    await hold("cancel")
    return try answer(r)
  }
  func definition(id: String) async throws -> BuildDefinition {
    let r = take("definition", "definition \(id)")
    await hold("definition")
    return try answer(r)
  }
  func deploy(id: String, hashes: DeployHashes) async throws -> Deployed {
    let r = take("deploy", "deploy \(id)", deploy: hashes)
    await hold("deploy")
    return try answer(r)
  }
  func outcomes(month: String) async throws -> [FixOutcome] {
    let r = take("outcomes", "outcomes \(month)")
    await hold("outcomes")
    return try answer(r)
  }
}

/// Fixtures. Synthetic: no real person's data.
enum M313F {
  static let utc = TimeZone(identifier: "UTC")!
  static let buildID = "0193a6f2-6c1e-7b51-9d2a-5f0e8c1b2a33"
  static let briefHash = "7c41e2" + String(repeating: "1", count: 58)
  static let checkSetHash = String(repeating: "2", count: 64)
  static let heldOutHash = String(repeating: "3", count: 64)
  static let fixtureSetHash = String(repeating: "4", count: 64)
  static let artifact = String(repeating: "a", count: 64)
  static let receipt = String(repeating: "b", count: 64)
  static let definitionHash = String(repeating: "c", count: 64)
  static let artifact1 = String(repeating: "d", count: 64)
  static let artifact3 = String(repeating: "e", count: 64)

  static func date(_ iso: String) -> Date { ISO8601DateFormatter().date(from: iso)! }

  static let cloudMode = BackendMode.cloud(BackendConfig(baseURL: URL(string: "https://api.example.test")!, tokens: M313Token()))

  static func decode<T: Decodable>(_ type: T.Type, _ json: String) -> T {
    try! JSONDecoder().decode(T.self, from: Data(json.utf8))
  }

  // MARK: Fix and opportunity

  static let fixJSON = #"{"id":"fix_1","brief":{"title":"PR pre-read tool","summary":"Reads each new pull request and posts a short summary card before review."},"brief_hash":"\#(briefHash)","check_set_hash":"\#(checkSetHash)","held_out_hash":"\#(heldOutHash)","fixture_set_hash":"\#(fixtureSetHash)","estimate":{"id":"fig_0000000000000001","value":1.4,"unit":"hours_per_week","arithmetic":"21 min x 4 per week = 1.4 h","evidence":[{"kind":"fix_estimate","id":"fix_1"}],"source_purged_at":null},"cap_usd":4,"x_unknown_field":true}"#

  static var fix: Fix { decode(Fix.self, fixJSON) }

  /// The same fix after the plan changed: a new brief hash.
  static var changedFix: Fix {
    var f = fix
    f.briefHash = "9f00d1" + String(repeating: "5", count: 58)
    return f
  }

  static func opportunity(_ state: String, missing: [String] = []) -> Opportunity {
    decode(Opportunity.self, opportunityJSON(state, missing: missing))
  }

  static func opportunityJSON(_ state: String, missing: [String] = []) -> String {
    let list = missing.map { "\"\($0)\"" }.joined(separator: ",")
    return #"{"id":"opp_1","source":"finder","title":"PR pre-read tool","state":"\#(state)","options":[{"id":"fix_2","option_no":2,"title":"A checklist"},{"id":"fix_1","option_no":1,"title":"A tool that reads each PR first","recommended":true}],"missing_connections":[\#(list)]}"#
  }

  // MARK: Builds (the build loop's buildView)

  /// Ready: worker 1 failed the frozen check, the fan-out's workers 2 and 3 passed, worker 2 won. 6m 12s, $0.84.
  static let readyJSON = #"{"id":"\#(buildID)","state":"ready","cap_usd":4,"spent_usd":0.84,"fanout_workers":2,"stages":[{"name":"teeth_gate","state":"done","started_at":"2026-11-22T11:50:00.000Z","ended_at":"2026-11-22T11:50:40.000Z","note":null},{"name":"worker","state":"done","started_at":"2026-11-22T11:50:40.000Z","ended_at":"2026-11-22T11:52:10.000Z","note":null},{"name":"verification","state":"failed","started_at":"2026-11-22T11:52:10.000Z","ended_at":"2026-11-22T11:52:30.000Z","note":"The first worker did not pass: Failed the frozen check in a fresh sandbox."},{"name":"fan_out","state":"done","started_at":"2026-11-22T11:52:30.000Z","ended_at":"2026-11-22T11:55:40.000Z","note":null},{"name":"winner","state":"done","started_at":"2026-11-22T11:55:40.000Z","ended_at":"2026-11-22T11:56:12.000Z","note":"Worker 2 passed every check in fresh sandboxes."}],"attempts":[{"id":"att_1","ordinal":1,"outcome":"fail","spent_usd":0.31,"tries":2,"turns":11,"frozen_pass":false,"held_out_pass":true,"check_groups":[{"name":"frozen","passed":0,"failed":1},{"name":"held_out","passed":1,"failed":0}],"artifact_sha256":"\#(artifact1)","artifact_bytes":4096,"artifact_files":["routine.json"],"note":"Failed the frozen check in a fresh sandbox."},{"id":"att_2","ordinal":2,"outcome":"pass","spent_usd":0.27,"tries":1,"turns":8,"frozen_pass":true,"held_out_pass":true,"check_groups":[{"name":"frozen","passed":1,"failed":0},{"name":"held_out","passed":1,"failed":0}],"artifact_sha256":"\#(artifact)","artifact_bytes":5120,"artifact_files":["routine.json","main.ts"],"note":"Passed every check in fresh sandboxes."},{"id":"att_3","ordinal":3,"outcome":"pass","spent_usd":0.26,"tries":1,"turns":9,"frozen_pass":true,"held_out_pass":true,"check_groups":[{"name":"frozen","passed":1,"failed":0},{"name":"held_out","passed":1,"failed":0}],"artifact_sha256":"\#(artifact3)","artifact_bytes":6144,"artifact_files":["routine.json","main.ts"],"note":"Passed every check in fresh sandboxes."}],"winner_attempt_id":"att_2","artifact_sha256":"\#(artifact)","receipt_hash":"\#(receipt)","definition_hash":"\#(definitionHash)","deployed":false,"started_at":"2026-11-22T11:50:00.000Z","ended_at":"2026-11-22T11:56:12.000Z"}"#

  /// Fanning out: worker 1 failed, workers 2 and 3 are running. $0.31 so far, no end.
  static let fanningOutJSON = #"{"id":"\#(buildID)","state":"fanning_out","cap_usd":4,"spent_usd":0.31,"fanout_workers":2,"stages":[{"name":"teeth_gate","state":"done","started_at":"2026-11-22T11:50:00.000Z","ended_at":"2026-11-22T11:50:40.000Z","note":null},{"name":"worker","state":"done","started_at":"2026-11-22T11:50:40.000Z","ended_at":"2026-11-22T11:52:10.000Z","note":null},{"name":"verification","state":"failed","started_at":"2026-11-22T11:52:10.000Z","ended_at":"2026-11-22T11:52:30.000Z","note":"The first worker did not pass: Failed the frozen check in a fresh sandbox."},{"name":"fan_out","state":"running","started_at":"2026-11-22T11:52:30.000Z","ended_at":null,"note":null}],"attempts":[{"id":"att_1","ordinal":1,"outcome":"fail","spent_usd":0.31,"tries":2,"turns":11,"frozen_pass":false,"held_out_pass":true,"check_groups":[{"name":"frozen","passed":0,"failed":1},{"name":"held_out","passed":1,"failed":0}],"artifact_sha256":null,"artifact_bytes":0,"artifact_files":[],"note":"Failed the frozen check in a fresh sandbox."},{"id":"att_2","ordinal":2,"outcome":"running","spent_usd":0,"tries":0,"turns":0,"frozen_pass":null,"held_out_pass":null,"check_groups":[],"artifact_sha256":null,"artifact_bytes":0,"artifact_files":[],"note":"This worker is building."},{"id":"att_3","ordinal":3,"outcome":"running","spent_usd":0,"tries":0,"turns":0,"frozen_pass":null,"held_out_pass":null,"check_groups":[],"artifact_sha256":null,"artifact_bytes":0,"artifact_files":[],"note":"This worker is building."}],"winner_attempt_id":null,"artifact_sha256":null,"receipt_hash":null,"definition_hash":null,"deployed":false,"started_at":"2026-11-22T11:50:00.000Z","ended_at":null}"#

  static var ready: Build { decode(Build.self, readyJSON) }
  static var fanningOut: Build { decode(Build.self, fanningOutJSON) }

  /// The ready build with another state (the rest unchanged).
  static func readyAs(_ state: BuildState, deployed: Bool = false) -> Build {
    var b = ready
    b.state = state
    b.deployed = deployed
    return b
  }

  /// A build with only these stages and attempts.
  static func build(_ state: BuildState, stages: [BuildStage] = [], attempts: [BuildAttempt] = [], winner: String? = nil,
                    started: String? = "2026-11-22T11:50:00.000Z", ended: String? = nil, spent: Double = 0) -> Build {
    Build(id: buildID, state: state, capUSD: 4, spentUSD: spent, fanoutWorkers: 2, stages: stages, attempts: attempts,
          winnerAttemptID: winner, artifactSHA256: nil, receiptHash: nil, definitionHash: nil, deployed: false,
          startedAt: started, endedAt: ended)
  }

  static func stage(_ name: String, _ state: BuildStageState, note: String? = nil) -> BuildStage {
    BuildStage(name: name, state: state, startedAt: "2026-11-22T11:50:00.000Z", endedAt: nil, note: note)
  }

  static func attempt(_ ordinal: Int, _ outcome: AttemptOutcome, frozen: Bool? = nil, heldOut: Bool? = nil,
                      groups: [CheckGroup] = [], spent: Double = 0) -> BuildAttempt {
    BuildAttempt(id: "att_\(ordinal)", ordinal: ordinal, outcome: outcome, spentUSD: spent, tries: 1, turns: 1,
                 frozenPass: frozen, heldOutPass: heldOut, checkGroups: groups, artifactSHA256: nil, artifactBytes: 0,
                 artifactFiles: [], note: nil)
  }

  static let definitionJSON = #"{"definition":{"trigger":{"kind":"event","on":"pull_request.opened"},"steps":[{"capability":"github.read"}]},"definition_hash":"\#(definitionHash)","words":["When a pull request opens","Reads the pull request, never writes to it","Posts a summary card on this Mac"]}"#
  static var definition: BuildDefinition { decode(BuildDefinition.self, definitionJSON) }

  /// The same definition after it changed on the server.
  static var changedDefinition: BuildDefinition {
    var d = definition
    d.definitionHash = String(repeating: "f", count: 64)
    return d
  }

  static func outcome(_ flag: String, weeks: String = "[]", ratio: String = "0.86", estimated: String = "84") -> FixOutcome {
    decode(FixOutcome.self, #"{"routine_id":"rt_1","shipped_at":"2026-11-22T12:10:00Z","estimated_minutes_per_week":{"id":"fig_0000000000000002","value":\#(estimated),"unit":"minutes_per_week","arithmetic":"1.4 h x 60 = 84 min/week","evidence":[{"kind":"fix_estimate","id":"fix_1"}],"source_purged_at":null},"baseline_minutes_per_week":120,"weeks":\#(weeks),"flag":"\#(flag)","ratio":\#(ratio),"arithmetic":"72.24 min measured / 84 min estimated = 0.86"}"#)
  }

  static func record(_ id: String = buildID, name: String = "PR pre-read tool", fixID: String? = "fix_1",
                     at iso: String = "2026-11-22T11:50:00Z", routineID: String? = nil, installedAt: Date? = nil) -> BuildRecord {
    BuildRecord(buildID: id, name: name, fixID: fixID, startedAt: date(iso), routineID: routineID, installedAt: installedAt)
  }

  static let offline = APIError.transport(code: URLError.Code.notConnectedToInternet.rawValue)

  static func server(_ status: Int, _ code: String, _ message: String = "") -> APIError {
    .server(status: status, code: APIErrorCode(raw: code), message: message, requestID: "req_01JCA0000000000000000000Z9", ruleID: nil)
  }
}

/// Models over the fakes.
@MainActor
enum M313M {
  static func cloud(_ client: M313Client, store: MemoryBuildRecordStore = MemoryBuildRecordStore(),
                    plans: MemoryPlanRecordStore = MemoryPlanRecordStore(),
                    sleeper: M313Sleeper = M313Sleeper(), now: M313Now = M313Now()) -> BuildProgressModel {
    let model = BuildProgressModel(mode: M313F.cloudMode, client: client, store: store, plans: plans, sleeper: sleeper,
                                   now: { now.date }, timeZone: M313F.utc)
    model.activate()
    return model
  }

  static func local(store: MemoryBuildRecordStore = MemoryBuildRecordStore(), sleeper: M313Sleeper = M313Sleeper()) -> BuildProgressModel {
    let model = BuildProgressModel(mode: .local, client: nil, store: store, sleeper: sleeper,
                                   now: { M313F.date("2026-11-22T12:00:00Z") }, timeZone: M313F.utc)
    model.activate()
    return model
  }

  /// A cloud model with one record whose build is `build`, selected after a refresh.
  static func selected(_ build: Build, client: M313Client = M313Client(), record: BuildRecord = M313F.record(fixID: nil),
                       sleeper: M313Sleeper = M313Sleeper()) async -> (BuildProgressModel, M313Client, MemoryBuildRecordStore) {
    let store = MemoryBuildRecordStore([record])
    client.script("build", .value(build))
    let model = cloud(client, store: store, sleeper: sleeper)
    await model.refresh()
    return (model, client, store)
  }
}
