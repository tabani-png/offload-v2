// Device tokens (15 minutes) by the challenge path of API.md section 2: ask for a nonce, sign it with the device key,
// exchange it for a token. Audience `device` for ingest and device commands; `member` for the routes a person could
// call from the web app (`/v1/imports`, `/v1/me/...`; API.md section 1, Auth). One session per audience.
import Foundation
import OffloadContracts

public protocol TokenProvider: Sendable {
    func token(forceRefresh: Bool) async throws -> String
}

public struct StaticTokenProvider: TokenProvider {
    private let value: String

    public init(token: String) { value = token }

    public func token(forceRefresh: Bool) async throws -> String { value }
}

public enum TokenError: Error, Equatable, Sendable {
    case rejected(Int)
    case malformed
}

/// The `aud` a device token is minted for.
public enum TokenAudience: String, Sendable {
    case device
    case member
}

public actor DeviceSession: TokenProvider {
    private let apiBase: URL
    private let deviceID: String
    private let signer: any DeviceSigner
    private let transport: any HTTPTransport
    private let time: any TimeSource
    private let audience: TokenAudience
    private var cached: (token: String, expires: Date)?

    public init(apiBase: URL, deviceID: String, signer: any DeviceSigner, transport: any HTTPTransport, time: any TimeSource,
                audience: TokenAudience = .device) {
        self.audience = audience
        self.apiBase = apiBase
        self.deviceID = deviceID
        self.signer = signer
        self.transport = transport
        self.time = time
    }

    public func token(forceRefresh: Bool) async throws -> String {
        if !forceRefresh, let cached, cached.expires.timeIntervalSince(time.now) > 60 { return cached.token }
        let challenge = try await post("v1/devices/challenge", ["device_id": deviceID, "audience": audience.rawValue])
        guard let nonce = challenge["nonce"] as? String else { throw TokenError.malformed }
        let signature = Base64URL.encode(try signer.sign(Data(nonce.utf8)))
        let issued = try await post("v1/devices/token", ["device_id": deviceID, "nonce": nonce, "signature": signature])
        guard let token = issued["token"] as? String, let expires = (issued["expires_at"] as? String).flatMap(Timestamp.parse) else {
            throw TokenError.malformed
        }
        cached = (token, expires)
        return token
    }

    private func post(_ path: String, _ body: [String: String]) async throws -> [String: Any] {
        let request = HTTPRequest(
            url: apiBase.appendingPathComponent(path), method: "POST", headers: ["Content-Type": "application/json"],
            body: try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]))
        let response = try await transport.send(request)
        guard (200..<300).contains(response.status) else { throw TokenError.rejected(response.status) }
        guard let json = try JSONSerialization.jsonObject(with: response.body) as? [String: Any] else { throw TokenError.malformed }
        return json
    }
}
