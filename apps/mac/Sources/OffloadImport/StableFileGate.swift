import Foundation

// Ported from PR #44 (app/Sources/Core/Recordings.swift `StableFileGate`).

/// A recording is read only when its size is non-zero and unchanged for `settle` seconds (still being written
/// otherwise). The time comes from the caller, so tests move it.
public struct StableFileGate: Sendable {
  struct Seen: Sendable {
    var size: Int64
    var since: Date
  }

  public let settle: TimeInterval
  private var seen: [String: Seen] = [:]

  public init(settle: TimeInterval = 3) { self.settle = settle }

  public mutating func observe(path: String, size: Int64, at date: Date) -> Bool {
    observe(path: path, size: size, modified: nil, at: date)
  }

  /// `modified` is the file's modification time: a file that has not been written to for `settle` seconds has kept
  /// its size at least that long, so it is ready at once.
  public mutating func observe(path: String, size: Int64, modified: Date?, at date: Date) -> Bool {
    guard size > 0 else {
      seen[path] = nil
      return false
    }
    if let s = seen[path], s.size == size { return date.timeIntervalSince(s.since) >= settle }
    let since = seen[path] == nil ? min(date, modified ?? date) : date
    seen[path] = Seen(size: size, since: since)
    return date.timeIntervalSince(since) >= settle
  }
}
