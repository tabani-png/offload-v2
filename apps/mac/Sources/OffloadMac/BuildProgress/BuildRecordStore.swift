import Foundation

// The builds started on this Mac (SPEC m3-13 "BuildRecordStore"). The API has no list route for builds, so the Mac
// keeps the ids of the builds it started, with the name the person saw and, after install, the routine it became. Ids,
// a name and dates only: no hashes, no definition, nothing from a screen. The labelled sample is never written here.

public struct BuildRecord: Codable, Equatable, Sendable {
  public var buildID: String
  /// The opportunity's (or repeat's) name, as shown when OK, build was pressed.
  public var name: String
  public var fixID: String?
  public var startedAt: Date
  /// The routine the deploy approval installed (`routine_id` from the 201), to find its outcome.
  public var routineID: String?
  public var installedAt: Date?

  public init(buildID: String, name: String, fixID: String?, startedAt: Date, routineID: String? = nil, installedAt: Date? = nil) {
    self.buildID = buildID
    self.name = name
    self.fixID = fixID
    self.startedAt = startedAt
    self.routineID = routineID
    self.installedAt = installedAt
  }

  enum CodingKeys: String, CodingKey {
    case buildID = "build_id"
    case name
    case fixID = "fix_id"
    case startedAt = "started_at"
    case routineID = "routine_id"
    case installedAt = "installed_at"
  }
}

@MainActor
public protocol BuildRecordStore: AnyObject {
  /// Every record, newest `startedAt` first.
  func records() -> [BuildRecord]
  /// Adds `record`, or replaces the record with the same build id.
  func add(_ record: BuildRecord)
  func remove(buildID: String)
}

extension BuildRecordStore {
  public func record(_ buildID: String) -> BuildRecord? { records().first { $0.buildID == buildID } }
}

enum BuildRecordList {
  static func sorted(_ list: [BuildRecord]) -> [BuildRecord] {
    list.sorted { a, b in a.startedAt != b.startedAt ? a.startedAt > b.startedAt : a.buildID < b.buildID }
  }

  static func adding(_ record: BuildRecord, to list: [BuildRecord]) -> [BuildRecord] {
    sorted(list.filter { $0.buildID != record.buildID } + [record])
  }
}

/// For tests and previews.
@MainActor
public final class MemoryBuildRecordStore: BuildRecordStore {
  private var list: [BuildRecord]

  public init(_ records: [BuildRecord] = []) { list = BuildRecordList.sorted(records) }

  public func records() -> [BuildRecord] { list }
  public func add(_ record: BuildRecord) { list = BuildRecordList.adding(record, to: list) }
  public func remove(buildID: String) { list.removeAll { $0.buildID == buildID } }
}

/// The app's store: one JSON list under `key`. An unreadable list reads as empty.
@MainActor
public final class UserDefaultsBuildRecordStore: BuildRecordStore {
  public static let key = "ai.offload.builds.startedOnThisMac"
  private let defaults: UserDefaults

  public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

  public func records() -> [BuildRecord] {
    guard let data = defaults.data(forKey: Self.key),
          let list = try? JSONDecoder().decode([BuildRecord].self, from: data)
    else { return [] }
    return BuildRecordList.sorted(list)
  }

  public func add(_ record: BuildRecord) { save(BuildRecordList.adding(record, to: records())) }

  public func remove(buildID: String) { save(records().filter { $0.buildID != buildID }) }

  private func save(_ list: [BuildRecord]) {
    if list.isEmpty {
      defaults.removeObject(forKey: Self.key)
    } else if let data = try? JSONEncoder().encode(list) {
      defaults.set(data, forKey: Self.key)
    }
  }
}
