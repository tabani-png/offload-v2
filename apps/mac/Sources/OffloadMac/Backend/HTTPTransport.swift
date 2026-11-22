import Foundation

// The one place a request leaves the Mac for the API (SPEC m3-10 "Backend/"). `URLSessionTransport` is the real one;
// tests use `RecordingTransport` and never touch the network.

public protocol HTTPTransport: Sendable {
  func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// An ephemeral session: no cookies, no cache, no credential store, and redirects are not followed (a redirect could
/// carry the member token to another host; the 3xx comes back as a bad response instead).
public final class URLSessionTransport: HTTPTransport, @unchecked Sendable {
  private let session: URLSession

  public init(timeout: TimeInterval = 30) {
    let config = URLSessionConfiguration.ephemeral
    config.httpCookieStorage = nil
    config.httpShouldSetCookies = false
    config.httpCookieAcceptPolicy = .never
    config.urlCache = nil
    config.urlCredentialStorage = nil
    config.requestCachePolicy = .reloadIgnoringLocalCacheData
    config.timeoutIntervalForRequest = timeout
    session = URLSession(configuration: config, delegate: RedirectRefuser(), delegateQueue: nil)
  }

  deinit {
    session.finishTasksAndInvalidate()
  }

  public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse else { throw APIError.badResponse(status: 0) }
    return (data, http)
  }
}

/// Refuses every redirect.
final class RedirectRefuser: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest
  ) async -> URLRequest? {
    nil
  }
}

/// A transport for tests and previews: records every request and answers with scripted replies in order, then with
/// `fallback`. Thread-safe.
public final class RecordingTransport: HTTPTransport, @unchecked Sendable {
  public enum Reply: Sendable, Equatable {
    /// An HTTP response with this status and body (`application/json`).
    case status(Int, body: Data)
    /// The request never reached the server (`URLError.notConnectedToInternet`).
    case offline

    /// A JSON reply from text.
    public static func json(_ status: Int, _ text: String) -> Reply { .status(status, body: Data(text.utf8)) }
  }

  private let lock = NSLock()
  private var recorded: [URLRequest] = []
  private var scripted: [Reply]
  private let fallback: Reply

  public init(replies: [Reply] = [], fallback: Reply = .json(200, "{}")) {
    scripted = replies
    self.fallback = fallback
  }

  /// Adds a reply after the ones already scripted.
  public func enqueue(_ reply: Reply) {
    lock.lock()
    defer { lock.unlock() }
    scripted.append(reply)
  }

  /// Every request sent so far, in order.
  public var requests: [URLRequest] {
    lock.lock()
    defer { lock.unlock() }
    return recorded
  }

  public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    let reply = take(request)
    switch reply {
    case .offline:
      throw URLError(.notConnectedToInternet)
    case .status(let status, let body):
      let url = request.url ?? URL(string: "https://invalid.example")!
      guard let http = HTTPURLResponse(
        url: url, statusCode: status, httpVersion: "HTTP/1.1",
        headerFields: ["Content-Type": "application/json; charset=utf-8"]
      ) else {
        throw APIError.badResponse(status: status)
      }
      return (body, http)
    }
  }

  /// Synchronous, because NSLock may not be used directly from an async function.
  private func take(_ request: URLRequest) -> Reply {
    lock.lock()
    defer { lock.unlock() }
    recorded.append(request)
    return scripted.isEmpty ? fallback : scripted.removeFirst()
  }
}
