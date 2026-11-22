// The Mac egress guard (ADR 0035): one destination, closed schemas, detectors again on every object, fail closed.
import CryptoKit
import Foundation
import OffloadContracts
import OffloadMasker

public enum EgressError: Error, Equatable, Sendable {
    /// A request to anything but the configured API host (and port, and scheme).
    case refusedDestination(String)
    /// A device detector fired on an object that should already be masked.
    case detectorHit(detector: String, objectID: String)
    /// An object that does not survive the closed schema.
    case invalidObject(String)
    case invalidEnvelope
}

public struct EgressGuard: Sendable {
    public let host: String
    private let scheme: String
    private let port: Int

    public init(apiBase: URL) {
        host = (apiBase.host ?? "").lowercased()
        scheme = (apiBase.scheme ?? "https").lowercased()
        port = apiBase.port ?? (scheme == "https" ? 443 : 80)
    }

    /// Only the configured scheme, host and port; no user info.
    public func check(url: URL) throws {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false), let h = parts.host?.lowercased(),
              let s = parts.scheme?.lowercased() else { throw EgressError.refusedDestination("unparseable") }
        let p = parts.port ?? (s == "https" ? 443 : 80)
        guard s == scheme, h == host, p == port, parts.user == nil, parts.password == nil, !host.isEmpty else {
            throw EgressError.refusedDestination(h)
        }
    }

    /// Fails when an object leaves the closed schema or a detector fires on any of its text.
    public func inspect(_ object: Observation) throws {
        let data: Data
        do {
            data = try JSONEncoder().encode(object)
            _ = try JSONDecoder().decode(Observation.self, from: data)
        } catch {
            throw EgressError.invalidObject(object.id)
        }
        for value in Self.texts(of: object) {
            if let hit = LeakScan.scan(value) { throw EgressError.detectorHit(detector: hit, objectID: object.id) }
            if !LeakScan.disallowedTokens(value).isEmpty { throw EgressError.detectorHit(detector: "token", objectID: object.id) }
        }
        if case .textSnapshot(let t) = object {
            let hash = SHA256.hash(data: Data(t.text.utf8)).map { String(format: "%02x", $0) }.joined()
            if hash != t.textHash { throw EgressError.invalidObject(object.id) }
        }
    }

    /// Detector hits over a batch (zero for every detector when it may leave) and the pseudonyms it carries, for the ledger.
    public func summary(of objects: [Observation]) -> (detectors: [String: Int], pseudonyms: [String: Int]) {
        var detectors = Dictionary(uniqueKeysWithValues: LeakScan.detectorNames.map { ($0, 0) })
        var pseudonyms = Dictionary(uniqueKeysWithValues: PseudonymKind.allCases.map { ($0.rawValue, 0) })
        let token = try? NSRegularExpression(pattern: #"<(person|email|phone|doc):h_[0-9a-f]{16}>"#)
        for o in objects {
            for value in Self.texts(of: o) {
                if let hit = LeakScan.scan(value) { detectors[hit, default: 0] += 1 }
                let ns = value as NSString
                for m in token?.matches(in: value, options: [], range: NSRange(location: 0, length: ns.length)) ?? [] where m.numberOfRanges > 1 {
                    pseudonyms[ns.substring(with: m.range(at: 1)), default: 0] += 1
                }
            }
        }
        return (detectors, pseudonyms)
    }

    /// Every free-text field of an observation.
    static func texts(of object: Observation) -> [String] {
        switch object {
        case .focus(let f): return [f.appBundleId, f.appName] + [f.title, f.host, f.doc].compactMap { $0 }
        case .textSnapshot(let t): return [t.appBundleId, t.text]
        default: return []
        }
    }
}

/// Wraps a transport so that a request to any other destination never reaches it.
public struct GuardedTransport: HTTPTransport {
    private let inner: any HTTPTransport
    private let egress: EgressGuard

    public init(inner: any HTTPTransport, guard egress: EgressGuard) {
        self.inner = inner
        self.egress = egress
    }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        try egress.check(url: request.url)
        return try await inner.send(request)
    }
}
