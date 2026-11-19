import CryptoKit
import Foundation

// Ported from PR #44 (engine/Sources/OffloadCore/Recordings/RecordingLedger.swift). Which files were already read,
// so a folder is imported once per file version. It holds a SHA-256 fingerprint of (path, size, modified time), the
// import space and counts only: no file names, no paths, no text. File 0600, folder 0700.

public enum RecordingFingerprint {
  public static func of(path: String, size: Int64, modified: Date) -> String {
    let modifiedMs = Int64((modified.timeIntervalSince1970 * 1000).rounded())
    return ImportWire.hex(SHA256.hash(data: Data("\(path)\u{0}\(size)\u{0}\(modifiedMs)".utf8)))
  }
}

public struct RecordingLedgerEntry: Codable, Equatable, Sendable {
  public var fingerprint: String
  public var importID: String
  public var ingestedAt: Date
  /// When the recording (or the first row or screenshot) was made.
  public var recordedAt: Date
  /// Frames or rows read.
  public var moments: Int

  public init(fingerprint: String, importID: String, ingestedAt: Date, recordedAt: Date, moments: Int) {
    self.fingerprint = fingerprint
    self.importID = importID
    self.ingestedAt = ingestedAt
    self.recordedAt = recordedAt
    self.moments = moments
  }
}

public protocol RecordingLedger: Sendable {
  func contains(_ fingerprint: String) -> Bool
  func record(_ entry: RecordingLedgerEntry) throws
  /// "Remove imported data": the import's files may be read again into a new import space.
  func removeEntries(importID: String) throws
  var entries: [RecordingLedgerEntry] { get }
}

public final class MemoryRecordingLedger: RecordingLedger, @unchecked Sendable {
  private let lock = NSLock()
  private var all: [RecordingLedgerEntry] = []

  public init() {}

  public func contains(_ fingerprint: String) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return all.contains { $0.fingerprint == fingerprint }
  }

  public func record(_ entry: RecordingLedgerEntry) throws {
    lock.lock()
    defer { lock.unlock() }
    all.append(entry)
  }

  public func removeEntries(importID: String) throws {
    lock.lock()
    defer { lock.unlock() }
    all.removeAll { $0.importID == importID }
  }

  public var entries: [RecordingLedgerEntry] {
    lock.lock()
    defer { lock.unlock() }
    return all
  }
}

public struct LedgerWriteError: Error, Equatable {
  public let step: String
}

/// The ledger as one JSON file, replaced atomically on every change.
public final class FileRecordingLedger: RecordingLedger, @unchecked Sendable {
  struct File: Codable {
    var schemaVersion = 1
    var entries: [RecordingLedgerEntry] = []
  }

  public let file: URL
  private let lock = NSLock()
  private var state: File

  public init(file: URL) {
    self.file = file
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .millisecondsSince1970
    if let data = try? Data(contentsOf: file), let f = try? decoder.decode(File.self, from: data), f.schemaVersion == 1 {
      state = f
    } else {
      state = File()
    }
  }

  public func contains(_ fingerprint: String) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return state.entries.contains { $0.fingerprint == fingerprint }
  }

  public func record(_ entry: RecordingLedgerEntry) throws {
    lock.lock()
    defer { lock.unlock() }
    var next = state
    next.entries.append(entry)
    try save(next)
    state = next
  }

  public func removeEntries(importID: String) throws {
    lock.lock()
    defer { lock.unlock() }
    var next = state
    next.entries.removeAll { $0.importID == importID }
    try save(next)
    state = next
  }

  public var entries: [RecordingLedgerEntry] {
    lock.lock()
    defer { lock.unlock() }
    return state.entries
  }

  private func save(_ f: File) throws {
    let fm = FileManager.default
    let dir = file.deletingLastPathComponent()
    try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    encoder.dateEncodingStrategy = .millisecondsSince1970
    let data = try encoder.encode(f)
    let tmp = dir.appendingPathComponent(".\(file.lastPathComponent).tmp")
    if fm.fileExists(atPath: tmp.path) { try? fm.removeItem(at: tmp) }
    guard fm.createFile(atPath: tmp.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
      throw LedgerWriteError(step: "create")
    }
    if rename(tmp.path, file.path) != 0 {
      try? fm.removeItem(at: tmp)
      throw LedgerWriteError(step: "rename")
    }
  }
}
