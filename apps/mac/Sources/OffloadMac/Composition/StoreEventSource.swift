// The local now line reads what the observer wrote (slice m3-14-mac-app-integration; W1-D audit gap 4): PR #13's
// encrypted day store, as m3-04's LocalEventSource. Read on this Mac only; nothing here sends anything. Imported
// observations (`source = "import"`) are never part of the live line.
import Foundation
import OffloadContracts
import OffloadStore

/// The capture runtime's day store, once capture has started. Empty before: nothing is opened before consent.
public final class StoreHandle: @unchecked Sendable {
  private let lock = NSLock()
  private var store: DayStore?

  public init() {}

  public var current: DayStore? { lock.withLock { store } }

  public func set(_ store: DayStore) { lock.withLock { self.store = store } }
}

public struct StoreEventSource: LocalEventSource {
  public let handle: StoreHandle

  public init(handle: StoreHandle) { self.handle = handle }

  /// Day names stop at year 9999, so a far `to` is clamped there.
  static let latestMs: Int64 = 253_402_300_799_000

  /// Events with `from < ts <= to`, plus the last focus at or before `from`: from the window's own days, else from the
  /// one stored day before them.
  public func events(from: Int64, to: Int64) -> [LocalEvent] {
    guard let store = handle.current, from < to else { return [] }
    let first = Self.day(from, store)
    let last = Self.day(min(to, Self.latestMs), store)
    let days = store.storedDays()
    var window: [LocalEvent] = []
    var carried: LocalEvent?
    for day in days where day >= first && day <= last {
      for e in Self.events(in: day, of: store) {
        if e.ts > from && e.ts <= to {
          window.append(e)
        } else if e.ts <= from, e.kind == "focus", carried.map({ e.ts >= $0.ts }) ?? true {
          carried = e
        }
      }
    }
    if carried == nil, let previous = days.last(where: { $0 < first }) {
      carried = Self.events(in: previous, of: store).filter { $0.kind == "focus" && $0.ts <= from }.max { $0.ts < $1.ts }
    }
    let ordered = window.sorted { a, b in a.ts != b.ts ? a.ts < b.ts : a.id < b.id }
    return (carried.map { [$0] } ?? []) + ordered
  }

  /// The earliest live observation stored on this Mac.
  public func captureStartedAt() -> Int64? {
    guard let store = handle.current else { return nil }
    for day in store.storedDays() {
      if let first = Self.events(in: day, of: store).map(\.ts).min() { return first }
    }
    return nil
  }

  /// One stored observation as a local event; nil for imports, permission changes and unreadable times.
  public static func event(_ o: Observation) -> LocalEvent? {
    guard o.originSource != .import, let date = Timestamp.parse(o.ts) else { return nil }
    let ms = Timestamp.millis(date)
    switch o {
    case .focus(let f): return LocalEvent(id: f.id, ts: ms, kind: "focus", app: f.appBundleId, appName: f.appName)
    case .idleStart(let v): return LocalEvent(id: v.id, ts: ms, kind: "idle_start", app: nil, appName: nil)
    case .idleEnd(let v): return LocalEvent(id: v.id, ts: ms, kind: "idle_end", app: nil, appName: nil)
    case .pause(let v): return LocalEvent(id: v.id, ts: ms, kind: "pause", app: nil, appName: nil)
    case .resume(let v): return LocalEvent(id: v.id, ts: ms, kind: "resume", app: nil, appName: nil)
    case .textSnapshot(let t): return LocalEvent(id: t.id, ts: ms, kind: "text_snapshot", app: t.appBundleId, appName: nil)
    case .inputCounts(let v): return LocalEvent(id: v.id, ts: ms, kind: "input", app: nil, appName: nil)
    case .permissionChange: return nil
    }
  }

  static func day(_ ms: Int64, _ store: DayStore) -> String {
    store.days.day(of: Date(timeIntervalSince1970: TimeInterval(ms) / 1000))
  }

  /// A day that cannot be read yields nothing (the line then says nothing was seen, honestly).
  static func events(in day: String, of store: DayStore) -> [LocalEvent] {
    ((try? store.read(day: day)) ?? []).compactMap(event)
  }
}

extension Observation {
  /// `source` of any kind (nil means live).
  var originSource: ObservationSource? {
    switch self {
    case .focus(let v): return v.source
    case .idleStart(let v): return v.source
    case .idleEnd(let v): return v.source
    case .inputCounts(let v): return v.source
    case .textSnapshot(let v): return v.source
    case .pause(let v): return v.source
    case .resume(let v): return v.source
    case .permissionChange(let v): return v.source
    }
  }

  /// `import_id` of any kind.
  var originImportID: String? {
    switch self {
    case .focus(let v): return v.importId
    case .idleStart(let v): return v.importId
    case .idleEnd(let v): return v.importId
    case .inputCounts(let v): return v.importId
    case .textSnapshot(let v): return v.importId
    case .pause(let v): return v.importId
    case .resume(let v): return v.importId
    case .permissionChange(let v): return v.importId
    }
  }
}
