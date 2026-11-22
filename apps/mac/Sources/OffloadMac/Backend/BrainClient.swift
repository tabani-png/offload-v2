import Foundation

// The brain's routes (API.md "Profile and privacy" and "Today, records and review"; brain port http/handlers.ts).
// Only in `.cloud` backend mode; `Backends.local` has no client.

public protocol BrainClient: Sendable {
  /// `GET /v1/profile`.
  func profile() async throws -> BrainProfile
  /// `PATCH /v1/profile` with only the keys set on `patch`.
  func updateProfile(_ patch: BrainProfilePatch) async throws -> BrainProfile
  /// `GET /v1/records/days/{day}`, `day` as `YYYY-MM-DD`.
  func dayRecord(day: String) async throws -> DayRecord
  /// `GET /v1/records/weeks/{isoWeek}`, `isoWeek` as `YYYY-Www`. A future week is `APIError.notFound`.
  func weekRecord(isoWeek: String) async throws -> WeekRecord
  /// `GET /v1/review/week?w={isoWeek}`. A future week is `APIError.notFound`.
  func weekReview(isoWeek: String) async throws -> WeekReview
  /// `POST /v1/review/answers`.
  func answer(_ body: ReviewAnswerRequest) async throws -> ReviewAnswer
}

public struct HTTPBrainClient: BrainClient {
  public let core: APIClientCore

  public init(core: APIClientCore) {
    self.core = core
  }

  public func profile() async throws -> BrainProfile {
    try await core.send(BrainProfile.self, .get, [.fixed("profile")])
  }

  public func updateProfile(_ patch: BrainProfilePatch) async throws -> BrainProfile {
    try await core.send(BrainProfile.self, .patch, [.fixed("profile")], body: patch.body)
  }

  public func dayRecord(day: String) async throws -> DayRecord {
    guard APIClientCore.isDay(day) else { throw APIError.refusedPath }
    return try await core.send(DayRecord.self, .get, [.fixed("records"), .fixed("days"), .id(day)])
  }

  public func weekRecord(isoWeek: String) async throws -> WeekRecord {
    guard APIClientCore.isISOWeek(isoWeek) else { throw APIError.refusedPath }
    return try await core.send(WeekRecord.self, .get, [.fixed("records"), .fixed("weeks"), .id(isoWeek)])
  }

  public func weekReview(isoWeek: String) async throws -> WeekReview {
    guard APIClientCore.isISOWeek(isoWeek) else { throw APIError.refusedPath }
    return try await core.send(
      WeekReview.self, .get, [.fixed("review"), .fixed("week")], query: [URLQueryItem(name: "w", value: isoWeek)]
    )
  }

  public func answer(_ body: ReviewAnswerRequest) async throws -> ReviewAnswer {
    try await core.send(ReviewAnswer.self, .post, [.fixed("review"), .fixed("answers")], body: body.body, creates: true)
  }
}
