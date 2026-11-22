import Foundation
import OffloadImport

// Builds and sends every API request (SPEC m3-10 "Backend/", API.md section 1). Requests go to the configured base
// URL's host only, under `<base>/v1/`; every path segment that comes from data (an id, a day, a week, a month) is
// checked before any request is built, so nothing can resolve to another host or path. The member token is read per
// request and is never logged or put into an error.

/// Signs approval bodies with the device key. Returns the whole `Offload-Signature` header value,
/// `keyid=<device_id>, sig=<base64url r‖s>`, over exactly `body`.
public protocol RequestSigner: Sendable {
  func signature(for body: Data) throws -> String
}

public enum HTTPMethod: String, Sendable {
  case get = "GET"
  case post = "POST"
  case patch = "PATCH"
}

/// One part of a `/v1` path: a fixed word written by this code, or a value from data that is checked first.
public enum APIPathPart: Sendable, Equatable {
  case fixed(String)
  case id(String)
}

public struct APIClientCore: Sendable {
  public let config: BackendConfig
  public let transport: any HTTPTransport
  public let signer: (any RequestSigner)?
  public let now: @Sendable () -> Date

  public init(
    config: BackendConfig,
    transport: any HTTPTransport,
    signer: (any RequestSigner)? = nil,
    now: @escaping @Sendable () -> Date = { Date() }
  ) {
    self.config = config
    self.transport = transport
    self.signer = signer
    self.now = now
  }

  // MARK: Path checks

  /// True when `segment` can be one path segment as is: 1 to 128 of `A-Z a-z 0-9 . _ -`, and no `..`. So `/`, `?`,
  /// `#`, `%`, `:`, whitespace and empty values are refused.
  public static func isSafeSegment(_ segment: String) -> Bool {
    // A lone "." is refused too: a server may normalise `/v1/builds/.` to the list route (review 1, finding 10).
    guard !segment.isEmpty, segment != ".", segment.count <= 128, !segment.contains("..") else { return false }
    for scalar in segment.unicodeScalars {
      switch scalar.value {
      case 0x61...0x7A, 0x41...0x5A, 0x30...0x39, 0x2E, 0x5F, 0x2D: continue  // a-z A-Z 0-9 . _ -
      default: return false
      }
    }
    return true
  }

  /// True when `value` has the shape of `pattern`, where `d` is one ASCII digit and any other character is itself
  /// ("dddd-dd-dd" is a day, "dddd-Wdd" an ISO week, "dddd-dd" a month).
  public static func matches(_ value: String, shape pattern: String) -> Bool {
    let v = Array(value.unicodeScalars)
    let p = Array(pattern.unicodeScalars)
    guard v.count == p.count else { return false }
    for (a, b) in zip(v, p) {
      if b == "d" {
        guard (0x30...0x39).contains(a.value) else { return false }
      } else if a != b {
        return false
      }
    }
    return true
  }

  public static func isDay(_ s: String) -> Bool { matches(s, shape: "dddd-dd-dd") }
  public static func isISOWeek(_ s: String) -> Bool { matches(s, shape: "dddd-Wdd") }
  public static func isMonth(_ s: String) -> Bool { matches(s, shape: "dddd-dd") }

  /// The URL for `path` under the configured base, or `APIError.refusedPath`.
  public func url(_ path: [APIPathPart], query: [URLQueryItem] = []) throws -> URL {
    guard var comps = URLComponents(url: config.baseURL, resolvingAgainstBaseURL: false),
          comps.scheme?.lowercased() == "https",
          let host = comps.host, !host.isEmpty
    else { throw APIError.refusedPath }
    var segments: [String] = []
    for part in path {
      switch part {
      case .fixed(let word):
        guard Self.isSafeSegment(word) else { throw APIError.refusedPath }
        segments.append(word)
      case .id(let value):
        guard Self.isSafeSegment(value) else { throw APIError.refusedPath }
        segments.append(value)
      }
    }
    var basePath = comps.path
    while basePath.hasSuffix("/") { basePath.removeLast() }
    comps.path = basePath + "/v1/" + segments.joined(separator: "/")
    comps.queryItems = query.isEmpty ? nil : query
    comps.fragment = nil
    comps.user = nil
    comps.password = nil
    guard let url = comps.url,
          let check = URLComponents(url: url, resolvingAgainstBaseURL: false),
          check.scheme?.lowercased() == "https",
          check.host == host,
          check.port == comps.port
    else { throw APIError.refusedPath }
    return url
  }

  // MARK: Requests

  /// The request for one call. `creates` adds an `Idempotency-Key` (ULID); `signed` adds `Offload-Signature` over
  /// the JCS body and is refused with `APIError.signingUnavailable` when there is no signer.
  public func request(
    _ method: HTTPMethod,
    _ path: [APIPathPart],
    query: [URLQueryItem] = [],
    body: JSONValue? = nil,
    creates: Bool = false,
    signed: Bool = false
  ) throws -> URLRequest {
    if signed && signer == nil { throw APIError.signingUnavailable }
    let target = try self.url(path, query: query)
    guard let token = config.tokens.currentToken()?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty
    else { throw APIError.notSignedIn }
    var bytes: Data?
    if let body {
      do {
        bytes = try JCS.encode(body)
      } catch {
        throw APIError.invalidBody
      }
    }
    var req = URLRequest(url: target, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
    req.httpMethod = method.rawValue
    req.httpShouldHandleCookies = false
    req.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
    req.setValue("application/json", forHTTPHeaderField: "Accept")
    if let bytes {
      req.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
      req.httpBody = bytes
    }
    if creates {
      req.setValue(ULIDGenerator().next(at: now()), forHTTPHeaderField: "Idempotency-Key")
    }
    if signed {
      guard let signer else { throw APIError.signingUnavailable }
      let signature: String
      do {
        signature = try signer.signature(for: bytes ?? Data())
      } catch {
        throw APIError.signingUnavailable
      }
      req.setValue(signature, forHTTPHeaderField: "Offload-Signature")
    }
    return req
  }

  /// Builds, sends and decodes one call. 2xx bodies decode as `T` (unknown fields ignored); 404 is
  /// `APIError.notFound`; other statuses decode the error envelope.
  public func send<T: Decodable>(
    _ type: T.Type,
    _ method: HTTPMethod,
    _ path: [APIPathPart],
    query: [URLQueryItem] = [],
    body: JSONValue? = nil,
    creates: Bool = false,
    signed: Bool = false
  ) async throws -> T {
    let req = try request(method, path, query: query, body: body, creates: creates, signed: signed)
    let result: (Data, HTTPURLResponse)
    do {
      result = try await transport.send(req)
    } catch let error as APIError {
      throw error
    } catch let error as URLError {
      throw APIError.transport(code: error.code.rawValue)
    } catch {
      throw APIError.transport(code: URLError.Code.unknown.rawValue)
    }
    let data = result.0
    let status = result.1.statusCode
    if (200..<300).contains(status) {
      do {
        return try JSONDecoder().decode(T.self, from: data)
      } catch {
        throw APIError.badResponse(status: status)
      }
    }
    if status == 404 { throw APIError.notFound }
    throw errorFrom(status: status, data: data)
  }

  /// The envelope as an `APIError`, with the member token removed from every server string.
  func errorFrom(status: Int, data: Data) -> APIError {
    guard let envelope = try? JSONDecoder().decode(APIErrorEnvelope.self, from: data) else {
      return .badResponse(status: status)
    }
    let e = envelope.error
    return .server(
      status: status,
      code: APIErrorCode(raw: e.code),
      message: redact(e.message ?? ""),
      requestID: e.requestID.map { redact($0) },
      ruleID: e.ruleID.map { redact($0) }
    )
  }

  func redact(_ s: String) -> String {
    guard let token = config.tokens.currentToken()?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty
    else { return s }
    return s.replacingOccurrences(of: token, with: "[member token]")
  }
}
