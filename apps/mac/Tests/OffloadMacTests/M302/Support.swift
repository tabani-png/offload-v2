// Shared fakes and fixtures for the M302 suite. Nothing here talks to the network, the Keychain or a real window.
import CryptoKit
import Foundation
import Testing

@testable import OffloadContracts
@testable import OffloadMasker
@testable import OffloadObserver
@testable import OffloadStore
@testable import OffloadUploader

enum Repo {
    /// The repository root, found from this file's path: <root>/apps/mac/Tests/OffloadMacTests/M302/Support.swift.
    static let root: URL = {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<6 { url.deleteLastPathComponent() }
        return url
    }()
    static let macSources = root.appendingPathComponent("apps/mac/Sources", isDirectory: true)
    static let fixtures = root.appendingPathComponent("packages/contracts/tests/fixtures", isDirectory: true)
}

let utc = TimeZone(identifier: "UTC")!
/// 2026-01-01T00:00:00Z.
let t0 = Date(timeIntervalSince1970: 1_767_225_600)

/// A fresh store home in the temp folder, an in-memory Keychain and a key ring over them.
final class TestHome: @unchecked Sendable {
    let url: URL
    let layout: StoreLayout
    let secrets = MemorySecretStore()
    let keys: KeyRing
    let days = DayCalendar(timeZone: utc)

    init() {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("offload-m302-\(UUID().uuidString)", isDirectory: true)
        layout = StoreLayout(home: url)
        keys = KeyRing(layout: layout, secrets: secrets)
    }

    deinit { try? FileManager.default.removeItem(at: url) }

    func dayStore() -> DayStore { DayStore(layout: layout, keys: keys, days: days) }
}

extension Observation {
    var kindName: String { kind }
}

func kinds(_ items: [Observation]) -> [String] { items.map { $0.kind } }

func snapshots(_ items: [Observation]) -> [ObservationTextSnapshot] {
    items.compactMap { if case .textSnapshot(let t) = $0 { return t } else { return nil } }
}

func focuses(_ items: [Observation]) -> [ObservationFocus] {
    items.compactMap { if case .focus(let f) = $0 { return f } else { return nil } }
}

func pauses(_ items: [Observation]) -> [ObservationPause] {
    items.compactMap { if case .pause(let p) = $0 { return p } else { return nil } }
}

func resumes(_ items: [Observation]) -> [ObservationResume] {
    items.compactMap { if case .resume(let p) = $0 { return p } else { return nil } }
}

func permissionChanges(_ items: [Observation]) -> [ObservationPermissionChange] {
    items.compactMap { if case .permissionChange(let p) = $0 { return p } else { return nil } }
}

// MARK: observer fakes (the observer and its sources run on the main actor)

@MainActor final class FakeWorkspace: WorkspaceSource {
    var snapshot: FocusSnapshot?
    func frontmost() -> FocusSnapshot? { snapshot }
}

@MainActor final class FakeIdle: IdleSource {
    var seconds: TimeInterval = 0
    func secondsSinceLastInput() -> TimeInterval { seconds }
}

@MainActor final class FakePower: PowerSource {
    var batteryFraction: Double?
}

@MainActor final class FakePermissions: PermissionSource {
    var state = PermissionState(screenRecording: true, accessibility: true)
    func current() -> PermissionState { state }
}

@MainActor final class FakePause: PauseSource {
    var reason: PauseReason?
    var current: PauseReason? { reason }
}

@MainActor final class FakeAX: AXTextSource {
    var text = ""
    private(set) var calls = 0
    func axText(of snapshot: FocusSnapshot) -> AXWalkResult? {
        calls += 1
        return AXWalkResult(text: text, visitedNodes: 1, deepest: 0, stop: .complete)
    }
}

@MainActor final class FakeOCR: OCRSource {
    var text: String? = ""
    private(set) var calls = 0
    func ocrText(of snapshot: FocusSnapshot) async throws -> String? {
        calls += 1
        return text
    }
}

/// Everything an observer needs, wired to fakes and a real encrypted day store in a temp folder.
@MainActor final class Rig {
    let home = TestHome()
    let time = ManualTime(t0)
    let workspace = FakeWorkspace()
    let idle = FakeIdle()
    let power = FakePower()
    let permissions = FakePermissions()
    let pause = FakePause()
    let ax = FakeAX()
    let ocr = FakeOCR()
    let store: DayStore
    let reveal: RevealMap
    let pseudonymizer = Pseudonymizer(key: PseudonymKey(data: Data(repeating: 7, count: 32)))
    let exclusionsFile: URL
    let observer: Observer

    init() {
        store = home.dayStore()
        reveal = RevealMap(layout: home.layout, keys: home.keys, days: home.days)
        exclusionsFile = home.url.appendingPathComponent("exclusions.json")
        observer = Observer(
            time: time, days: home.days, workspace: workspace, idle: idle, power: power, permissions: permissions,
            pause: pause, ax: ax, ocr: ocr, exclusions: ExclusionReloader(file: exclusionsFile, time: time),
            masker: TextMasker(pseudonymizer: pseudonymizer), sink: store, reveals: reveal, retention: nil)
        workspace.snapshot = FocusSnapshot(bundleID: "com.apple.mail", appName: "Mail", windowTitle: "Inbox", url: nil)
    }

    /// Moves the clock on by `seconds` and runs one observer tick.
    func tick(_ seconds: TimeInterval = 1) async {
        time.advance(by: seconds)
        await observer.tick()
    }

    func observed() throws -> [Observation] { try store.read(day: home.days.day(of: time.now)) }
}

// MARK: upload fakes

/// A scripted API: records every request and plays back a receipt, with the idempotency rules of API.md section 3.
final class FakeServer: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var log: [HTTPRequest] = []
    private var stored: [Int: (body: Data, receipt: Data)] = [:]
    var online = true
    /// Throw after recording and storing the batch, as if the process died before the receipt arrived.
    var dropNextResponse = false
    /// Answer the next batches with 409 seq_replay (stateless), then behave normally.
    var replayConflicts = 0

    var requests: [HTTPRequest] { lock.withLock { log } }
    var batchRequests: [HTTPRequest] { requests.filter { $0.url.path == "/v1/ingest/batches" } }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        try lock.withLock {
            if !online { throw URLError(.notConnectedToInternet) }
            log.append(request)
            guard request.url.path == "/v1/ingest/batches" else { return HTTPResponse(status: 404, headers: [:], body: Data()) }
            let json = try JSONSerialization.jsonObject(with: request.body ?? Data()) as? [String: Any] ?? [:]
            let seq = json["seq"] as? Int ?? -1
            if replayConflicts > 0 {
                replayConflicts -= 1
                return HTTPResponse(status: 409, headers: [:], body: Self.error("seq_replay"))
            }
            if let prior = stored[seq] {
                if prior.body == request.body { return HTTPResponse(status: 200, headers: [:], body: prior.receipt) }
                return HTTPResponse(status: 409, headers: [:], body: Self.error("seq_replay"))
            }
            let objects = json["objects"] as? [[String: Any]] ?? []
            let ids = objects.compactMap { $0["id"] as? String }
            let receipt = try JSONSerialization.data(withJSONObject: ["accepted": ids, "rejected": [Any]()], options: [.sortedKeys])
            stored[seq] = (request.body ?? Data(), receipt)
            if dropNextResponse {
                dropNextResponse = false
                throw URLError(.networkConnectionLost)
            }
            return HTTPResponse(status: 200, headers: [:], body: receipt)
        }
    }

    static func error(_ code: String) -> Data {
        Data("{\"error\":{\"code\":\"\(code)\",\"message\":\"x\",\"request_id\":\"r1\"}}".utf8)
    }
}

/// A device, a day store and an uploader over one temp home. `makeUploader()` again is a process restart.
@MainActor final class UploadRig {
    let home = TestHome()
    let time = ManualTime(t0)
    let server = FakeServer()
    let signer = SoftwareDeviceSigner()
    let config = UploaderConfig(apiBase: URL(string: "https://api.offload.example")!, deviceID: "0193a6f2-6c1e-7b51-9d2a-5f0e8c1b2a33")
    let store: DayStore
    let ids = ULIDGenerator()
    private var counter = 0

    init() { store = home.dayStore() }

    func makeUploader(transport: (any HTTPTransport)? = nil) -> Uploader {
        Uploader(
            config: config, transport: transport ?? server, signer: signer, tokens: StaticTokenProvider(token: "tok"),
            store: store, state: UploadStateStore(layout: home.layout, keys: home.keys),
            ledger: EgressLedger(layout: home.layout, keys: home.keys, days: home.days), time: time)
    }

    var ledger: EgressLedger { EgressLedger(layout: home.layout, keys: home.keys, days: home.days) }

    /// Appends a clean focus observation `secondsAgo` before the clock.
    @discardableResult
    func addFocus(title: String = "Finance 2026", secondsAgo: TimeInterval = 0) throws -> Observation {
        counter += 1
        let at = time.now.addingTimeInterval(-secondsAgo).addingTimeInterval(Double(counter) / 1000)
        let ms = Int64(at.timeIntervalSince1970 * 1000)
        let o = Observation.focus(ObservationFocus(
            id: ids.next(millis: ms), ts: Timestamp.format(at), appBundleId: "com.apple.mail", appName: "Mail", title: title))
        try store.append(o)
        return o
    }
}

func b64url(_ data: Data) -> String {
    data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

func unb64url(_ s: String) -> Data? {
    var t = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    while t.count % 4 != 0 { t += "=" }
    return Data(base64Encoded: t)
}

func sha256Hex(_ s: String) -> String { SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined() }
