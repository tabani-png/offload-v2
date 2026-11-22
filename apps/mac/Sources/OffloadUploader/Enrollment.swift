// Enrollment client (ADR 0014, API.md "Devices"): loopback HTTP listener on 127.0.0.1 on a random port, PKCE S256,
// `GET /v1/devices/authorize` in the system browser, then `POST /v1/devices/enroll`. The loopback listener is the only
// listening socket the Mac client opens, and it lives here with the rest of the network code, not in the observer.
import CryptoKit
import Foundation
import Network
import OffloadContracts
import Security

public enum PKCE {
    /// A fresh verifier (43 characters from 32 random bytes) and its S256 challenge.
    public static func generate() -> (verifier: String, challenge: String) {
        var bytes = [UInt8](repeating: 0, count: 32)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            for i in bytes.indices { bytes[i] = UInt8.random(in: 0...255) }
        }
        let verifier = Base64URL.encode(Data(bytes))
        return (verifier, challenge(forVerifier: verifier))
    }

    public static func challenge(forVerifier verifier: String) -> String {
        Base64URL.encode(Data(SHA256.hash(data: Data(verifier.utf8))))
    }
}

public enum EnrollmentURLs {
    public static func redirectURI(port: UInt16) -> String { "http://127.0.0.1:\(port)/callback" }

    /// The page the member signs in on, opened in the system browser.
    public static func authorize(apiBase: URL, challenge: String, port: UInt16, state: String) -> URL? {
        var parts = URLComponents(url: apiBase.appendingPathComponent("v1/devices/authorize"), resolvingAgainstBaseURL: false)
        parts?.queryItems = [
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "redirect_uri", value: redirectURI(port: port)),
            URLQueryItem(name: "state", value: state),
        ]
        return parts?.url
    }

    /// The `code` of a loopback request target (`/callback?code=...&state=...`), only for `/callback` and the right state.
    public static func parseCallback(_ target: String, expectedState: String) -> String? {
        guard let parts = URLComponents(string: "http://127.0.0.1" + target), parts.path == "/callback" else { return nil }
        let items = Dictionary((parts.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
        guard items["state"] == expectedState, let code = items["code"], !code.isEmpty else { return nil }
        return code
    }
}

public enum EnrollmentError: Error, Equatable, Sendable {
    case timedOut
    case listenerFailed
    case rejected(Int)
    case malformed
}

/// Listens on 127.0.0.1 for the browser's redirect and hands back the code.
public final class LoopbackListener: @unchecked Sendable {
    private let queue = DispatchQueue(label: "ai.offload.enrollment.loopback")
    private let lock = NSLock()
    private let expectedState: String
    private var listener: NWListener?
    private var waiter: CheckedContinuation<String, any Error>?
    private var outcome: Result<String, any Error>?

    public init(expectedState: String) { self.expectedState = expectedState }

    /// Starts listening and returns the port.
    public func start() async throws -> UInt16 {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        let made: NWListener
        do { made = try NWListener(using: parameters) } catch { throw EnrollmentError.listenerFailed }
        made.newConnectionHandler = { [weak self] connection in self?.handle(connection) }
        lock.withLock { listener = made }
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<UInt16, any Error>) in
            let once = Once()
            made.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if once.first() {
                        if let port = made.port?.rawValue { cont.resume(returning: port) } else { cont.resume(throwing: EnrollmentError.listenerFailed) }
                    }
                case .failed, .cancelled:
                    if once.first() { cont.resume(throwing: EnrollmentError.listenerFailed) }
                default:
                    break
                }
            }
            made.start(queue: queue)
        }
    }

    public func stop() { lock.withLock { listener?.cancel(); listener = nil } }

    /// The code from the redirect, or `timedOut`.
    public func waitForCode(timeout: TimeInterval) async throws -> String {
        try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask { try await self.awaitOutcome() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw EnrollmentError.timedOut
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw EnrollmentError.timedOut }
            return first
        }
    }

    private func awaitOutcome() async throws -> String {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, any Error>) in
            lock.lock()
            if let outcome {
                lock.unlock()
                cont.resume(with: outcome)
            } else {
                waiter = cont
                lock.unlock()
            }
        }
    }

    private func deliver(_ result: Result<String, any Error>) {
        lock.lock()
        guard outcome == nil else { lock.unlock(); return }
        outcome = result
        let w = waiter
        waiter = nil
        lock.unlock()
        w?.resume(with: result)
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, _ in
            guard let self else { connection.cancel(); return }
            let line = data.flatMap { String(data: $0, encoding: .utf8) }?.split(separator: "\r\n").first.map(String.init) ?? ""
            let parts = line.split(separator: " ")
            let code = parts.count >= 2 && parts[0] == "GET" ? EnrollmentURLs.parseCallback(String(parts[1]), expectedState: self.expectedState) : nil
            let page = code == nil ? "Offload could not read this sign-in. Close this tab and try again from the app." : "Offload is connected to this Mac. You can close this tab."
            let body = "<!doctype html><meta charset=\"utf-8\"><title>Offload</title><p>\(page)</p>"
            let head = "HTTP/1.1 \(code == nil ? "400 Bad Request" : "200 OK")\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
            connection.send(content: Data((head + body).utf8), completion: .contentProcessed { _ in connection.cancel() })
            if let code { self.deliver(.success(code)) }
        }
    }

    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var used = false

        func first() -> Bool { lock.withLock { if used { return false }; used = true; return true } }
    }
}

/// `POST /v1/devices/enroll` and the key-wrap upload.
public struct EnrollmentClient: Sendable {
    private let apiBase: URL
    private let transport: any HTTPTransport

    public init(apiBase: URL, transport: any HTTPTransport) {
        self.apiBase = apiBase
        self.transport = GuardedTransport(inner: transport, guard: EgressGuard(apiBase: apiBase))
    }

    /// The whole loopback flow: listen, open the browser, wait for the code, enroll. Returns the new device id.
    public func enroll(publicJWK: P256PublicJWK, keyStorage: String, deviceName: String, openBrowser: @Sendable (URL) -> Void,
                       timeout: TimeInterval = 600) async throws -> String {
        let pkce = PKCE.generate()
        var stateBytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, stateBytes.count, &stateBytes)
        let state = Base64URL.encode(Data(stateBytes))
        let listener = LoopbackListener(expectedState: state)
        let port = try await listener.start()
        defer { listener.stop() }
        guard let url = EnrollmentURLs.authorize(apiBase: apiBase, challenge: pkce.challenge, port: port, state: state) else { throw EnrollmentError.malformed }
        openBrowser(url)
        let code = try await listener.waitForCode(timeout: timeout)
        let jwk = try JSONSerialization.jsonObject(with: JSONEncoder().encode(publicJWK))
        let body: [String: Any] = [
            "code": code, "code_verifier": pkce.verifier, "redirect_uri": EnrollmentURLs.redirectURI(port: port),
            "public_jwk": jwk, "name": deviceName, "key_storage": keyStorage,
        ]
        let response = try await transport.send(HTTPRequest(
            url: apiBase.appendingPathComponent("v1/devices/enroll"), method: "POST", headers: ["Content-Type": "application/json"],
            body: try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])))
        guard response.status == 200 else { throw EnrollmentError.rejected(response.status) }
        guard let json = try JSONSerialization.jsonObject(with: response.body) as? [String: Any], let id = json["device_id"] as? String else {
            throw EnrollmentError.malformed
        }
        return id
    }

    /// `PUT /v1/devices/{id}/pseudonym-key-wrap` with the body from `KeyWrap.putBody(for:)`.
    public func putKeyWrap(deviceID: String, body: Data, tokens: any TokenProvider) async throws {
        let token = try await tokens.token(forceRefresh: false)
        let response = try await transport.send(HTTPRequest(
            url: apiBase.appendingPathComponent("v1/devices/\(deviceID)/pseudonym-key-wrap"), method: "PUT",
            headers: ["Content-Type": "application/json", "Authorization": "Bearer \(token)"], body: body))
        guard response.status == 204 else { throw EnrollmentError.rejected(response.status) }
    }
}
