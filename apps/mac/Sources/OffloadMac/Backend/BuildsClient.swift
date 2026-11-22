import Foundation

// Opportunities, fixes, builds and outcomes (API.md "Opportunities, fixes and builds" and "Metrics, audit and
// policy"; build-loop port http.ts). OK, build and deploy are approvals: their bodies are JCS bytes signed by the
// device key, and without a signer they are refused here with nothing sent. Only in `.cloud` backend mode.

public protocol BuildsClient: Sendable {
  /// `GET /v1/opportunities?state=open`.
  func openOpportunities() async throws -> [Opportunity]
  /// `GET /v1/opportunities/{id}`.
  func opportunity(id: String) async throws -> Opportunity
  /// `POST /v1/opportunities/{id}/answer` `{ answer, option_id? }`.
  func answerOpportunity(id: String, answer: OpportunityAnswer, optionID: String?) async throws -> Opportunity
  /// `GET /v1/fixes/{id}`.
  func fix(id: String) async throws -> Fix
  /// `POST /v1/fixes/{fixID}/build-approvals` (OK, build), signed. 202 `{ build_id }`.
  func okBuild(fixID: String, hashes: FixHashes) async throws -> BuildStarted
  /// `GET /v1/builds/{id}`.
  func build(id: String) async throws -> Build
  /// `POST /v1/builds/{id}/cancel`.
  func cancel(id: String) async throws -> Build
  /// `GET /v1/builds/{id}/definition`.
  func definition(id: String) async throws -> BuildDefinition
  /// `POST /v1/builds/{id}/deploy` (deploy approval), signed. 201 `{ routine_id, version }`.
  func deploy(id: String, hashes: DeployHashes) async throws -> Deployed
  /// `GET /v1/outcomes?month={month}`, `month` as `YYYY-MM`.
  func outcomes(month: String) async throws -> [FixOutcome]
}

public struct HTTPBuildsClient: BuildsClient {
  public let core: APIClientCore

  public init(core: APIClientCore) {
    self.core = core
  }

  public func openOpportunities() async throws -> [Opportunity] {
    let list = try await core.send(
      LossyList<Opportunity>.self, .get, [.fixed("opportunities")], query: [URLQueryItem(name: "state", value: "open")]
    )
    return list.items
  }

  public func opportunity(id: String) async throws -> Opportunity {
    try await core.send(Opportunity.self, .get, [.fixed("opportunities"), .id(id)])
  }

  public func answerOpportunity(id: String, answer: OpportunityAnswer, optionID: String?) async throws -> Opportunity {
    var body: [String: JSONValue] = ["answer": .string(answer.rawValue)]
    if let optionID { body["option_id"] = .string(optionID) }
    return try await core.send(
      Opportunity.self, .post, [.fixed("opportunities"), .id(id), .fixed("answer")], body: .object(body), creates: true
    )
  }

  public func fix(id: String) async throws -> Fix {
    try await core.send(Fix.self, .get, [.fixed("fixes"), .id(id)])
  }

  public func okBuild(fixID: String, hashes: FixHashes) async throws -> BuildStarted {
    try await core.send(
      BuildStarted.self, .post, [.fixed("fixes"), .id(fixID), .fixed("build-approvals")], body: hashes.body,
      creates: true, signed: true
    )
  }

  public func build(id: String) async throws -> Build {
    try await core.send(Build.self, .get, [.fixed("builds"), .id(id)])
  }

  public func cancel(id: String) async throws -> Build {
    try await core.send(Build.self, .post, [.fixed("builds"), .id(id), .fixed("cancel")])
  }

  public func definition(id: String) async throws -> BuildDefinition {
    try await core.send(BuildDefinition.self, .get, [.fixed("builds"), .id(id), .fixed("definition")])
  }

  public func deploy(id: String, hashes: DeployHashes) async throws -> Deployed {
    try await core.send(
      Deployed.self, .post, [.fixed("builds"), .id(id), .fixed("deploy")], body: hashes.body, creates: true,
      signed: true
    )
  }

  public func outcomes(month: String) async throws -> [FixOutcome] {
    guard APIClientCore.isMonth(month) else { throw APIError.refusedPath }
    let list = try await core.send(
      LossyList<FixOutcome>.self, .get, [.fixed("outcomes")], query: [URLQueryItem(name: "month", value: month)]
    )
    return list.items
  }
}
