import Foundation

// Where the on-device pieces keep their files: `Application Support/Offload/OnDevice/`. Folders 0700, files 0600,
// excluded from backups. Nothing here can open a connection (NONET test).

/// The folders of one Offload on-device store. Tests inject a temporary root.
public struct OnDevicePaths: Equatable, Sendable {
  /// `Application Support/Offload`: Offload's own data folder, never a recordings folder.
  public var offloadSupport: URL
  /// `…/Offload/OnDevice`.
  public var root: URL

  public init(offloadSupport: URL) {
    self.offloadSupport = offloadSupport
    self.root = offloadSupport.appendingPathComponent("OnDevice", isDirectory: true)
  }

  public var imports: URL { root.appendingPathComponent("imports", isDirectory: true) }
  public var ledger: URL { root.appendingPathComponent("ledger.json") }
  public var answers: URL { root.appendingPathComponent("answers.json") }
  public var pseudonymKey: URL { root.appendingPathComponent("pseudonym.key") }

  /// This user's Application Support folder.
  public static func live(fileManager: FileManager = .default) -> OnDevicePaths {
    let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
    return OnDevicePaths(offloadSupport: support.appendingPathComponent("Offload", isDirectory: true))
  }
}

public struct OnDeviceWriteError: Error, Equatable {
  public let step: String
}

public enum OnDeviceFiles {
  /// Creates `dir` (and its parents) and sets it to 0700, excluded from backups.
  public static func ensureFolder(_ dir: URL) throws {
    let fm = FileManager.default
    try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
    excludeFromBackup(dir)
  }

  public static func excludeFromBackup(_ url: URL) {
    var u = url
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    try? u.setResourceValues(values)
  }

  /// Writes `data` to `file` (0600, file protection until first unlock where the Mac supports it) in one step: a
  /// temporary file beside it, then a rename.
  public static func writeAtomically(_ data: Data, to file: URL) throws {
    let dir = file.deletingLastPathComponent()
    try ensureFolder(dir)
    let tmp = dir.appendingPathComponent(".\(file.lastPathComponent).tmp")
    try? FileManager.default.removeItem(at: tmp)
    try writeProtected(data, to: tmp)
    if rename(tmp.path, file.path) != 0 {
      try? FileManager.default.removeItem(at: tmp)
      throw OnDeviceWriteError(step: "rename")
    }
  }

  /// Creates `file` with `data`, 0600, protected until the first unlock after a restart (falls back to plain when the
  /// volume does not support data protection). Not complete protection: an import that runs while the screen locks,
  /// and the counting after it, must still be able to write and read (review 1, finding 6).
  public static func writeProtected(_ data: Data, to file: URL) throws {
    do {
      try data.write(to: file, options: [.withoutOverwriting, .completeFileProtectionUntilFirstUserAuthentication])
    } catch {
      guard FileManager.default.createFile(atPath: file.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
        throw OnDeviceWriteError(step: "create")
      }
    }
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
  }

  /// The POSIX mode of a file or folder.
  public static func mode(_ url: URL) -> Int? {
    (try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue
  }
}
