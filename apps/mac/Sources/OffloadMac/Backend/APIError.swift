import Foundation

// The API error envelope `{ error: { code, message, request_id, rule_id? } }` and the closed code list of API.md
// section 1, plus the failures the Mac finds before or without a server answer. No case and no description ever holds
// the member token: the client removes it from server messages before building the error.

/// The closed code list of API.md section 1. A code not in the list decodes to `.other(code)`.
public enum APIErrorCode: Equatable, Hashable, Sendable, Codable {
  // 400
  case invalidRequest, unknownKind, schemaInvalid, clockSkew
  // 401
  case unauthenticated, tokenExpired
  // 403
  case forbidden, policyDenied, featureNotLicensed, hashMismatch, consentMissing
  // 404
  case notFound
  // 409
  case alreadyRunning, approvalUsed, approvalExpired, idempotencyConflict, seqReplay, nonceUsed, lastOwner
  case stateConflict, staleNotice
  // 413
  case tooLarge
  // 422
  case leakDetected, teethGateFailed, budgetExceeded, recipientNotAllowed
  // 429
  case rateLimited
  // 5xx
  case serverError
  case other(String)

  public init(raw: String) {
    switch raw {
    case "invalid_request": self = .invalidRequest
    case "unknown_kind": self = .unknownKind
    case "schema_invalid": self = .schemaInvalid
    case "clock_skew": self = .clockSkew
    case "unauthenticated": self = .unauthenticated
    case "token_expired": self = .tokenExpired
    case "forbidden": self = .forbidden
    case "policy_denied": self = .policyDenied
    case "feature_not_licensed": self = .featureNotLicensed
    case "hash_mismatch": self = .hashMismatch
    case "consent_missing": self = .consentMissing
    case "not_found": self = .notFound
    case "already_running": self = .alreadyRunning
    case "approval_used": self = .approvalUsed
    case "approval_expired": self = .approvalExpired
    case "idempotency_conflict": self = .idempotencyConflict
    case "seq_replay": self = .seqReplay
    case "nonce_used": self = .nonceUsed
    case "last_owner": self = .lastOwner
    case "state_conflict": self = .stateConflict
    case "stale_notice": self = .staleNotice
    case "too_large": self = .tooLarge
    case "leak_detected": self = .leakDetected
    case "teeth_gate_failed": self = .teethGateFailed
    case "budget_exceeded": self = .budgetExceeded
    case "recipient_not_allowed": self = .recipientNotAllowed
    case "rate_limited": self = .rateLimited
    case "server_error": self = .serverError
    default: self = .other(raw)
    }
  }

  public var raw: String {
    switch self {
    case .invalidRequest: return "invalid_request"
    case .unknownKind: return "unknown_kind"
    case .schemaInvalid: return "schema_invalid"
    case .clockSkew: return "clock_skew"
    case .unauthenticated: return "unauthenticated"
    case .tokenExpired: return "token_expired"
    case .forbidden: return "forbidden"
    case .policyDenied: return "policy_denied"
    case .featureNotLicensed: return "feature_not_licensed"
    case .hashMismatch: return "hash_mismatch"
    case .consentMissing: return "consent_missing"
    case .notFound: return "not_found"
    case .alreadyRunning: return "already_running"
    case .approvalUsed: return "approval_used"
    case .approvalExpired: return "approval_expired"
    case .idempotencyConflict: return "idempotency_conflict"
    case .seqReplay: return "seq_replay"
    case .nonceUsed: return "nonce_used"
    case .lastOwner: return "last_owner"
    case .stateConflict: return "state_conflict"
    case .staleNotice: return "stale_notice"
    case .tooLarge: return "too_large"
    case .leakDetected: return "leak_detected"
    case .teethGateFailed: return "teeth_gate_failed"
    case .budgetExceeded: return "budget_exceeded"
    case .recipientNotAllowed: return "recipient_not_allowed"
    case .rateLimited: return "rate_limited"
    case .serverError: return "server_error"
    case .other(let raw): return raw
    }
  }

  public init(from decoder: any Decoder) throws {
    self.init(raw: try decoder.singleValueContainer().decode(String.self))
  }

  public func encode(to encoder: any Encoder) throws {
    var c = encoder.singleValueContainer()
    try c.encode(raw)
  }
}

public enum APIError: Error, Equatable, Sendable, CustomStringConvertible, LocalizedError {
  /// The server answered with the error envelope. `message` has the member token removed.
  case server(status: Int, code: APIErrorCode, message: String, requestID: String?, ruleID: String?)
  /// 404: a record or review that does not exist (a future week) or a route the server does not have.
  case notFound
  /// An approval (OK, build or deploy) needs the device key, which comes with enrollment; nothing was sent.
  case signingUnavailable
  /// A path segment (an id, day, week or month) could not be placed safely under the configured host and `/v1`, or
  /// the base URL is not https; nothing was sent.
  case refusedPath
  /// There is no member token; nothing was sent.
  case notSignedIn
  /// The body could not be written as JCS (a non-finite number); nothing was sent.
  case invalidBody
  /// The request did not reach the server. `code` is the `URLError` code (-1009 is offline).
  case transport(code: Int)
  /// The server answered with something that is not the expected JSON (or a non-2xx without the envelope).
  case badResponse(status: Int)

  /// True when the Mac is offline.
  public var isOffline: Bool {
    if case .transport(let code) = self {
      return code == URLError.Code.notConnectedToInternet.rawValue || code == URLError.Code.networkConnectionLost.rawValue
    }
    return false
  }

  /// The server's code, when the server sent the envelope.
  public var code: APIErrorCode? {
    if case .server(_, let code, _, _, _) = self { return code }
    if case .notFound = self { return .notFound }
    return nil
  }

  public var description: String {
    switch self {
    case .server(let status, let code, let message, let requestID, let ruleID):
      var s = "\(status) \(code.raw): \(message)"
      if let ruleID { s += " (rule \(ruleID))" }
      if let requestID { s += " [\(requestID)]" }
      return s
    case .notFound: return "not found"
    case .signingUnavailable: return "approvals need this Mac's device key, which comes with enrollment"
    case .refusedPath: return "the request path was refused before sending"
    case .notSignedIn: return "this Mac is not signed in"
    case .invalidBody: return "the request body could not be written"
    case .transport(let code): return "the request did not reach Offload (code \(code))"
    case .badResponse(let status): return "unexpected response from Offload (status \(status))"
    }
  }

  public var errorDescription: String? { description }
}

/// The wire envelope.
struct APIErrorEnvelope: Decodable {
  struct Body: Decodable {
    let code: String
    let message: String?
    let requestID: String?
    let ruleID: String?

    enum CodingKeys: String, CodingKey {
      case code, message
      case requestID = "request_id"
      case ruleID = "rule_id"
    }
  }

  let error: Body
}
