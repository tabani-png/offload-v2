import AppKit

/// The file steps of screen 0's "Move and reopen", behind a protocol so the decision is tested without touching disk.
@MainActor
public protocol AppFileOps: AnyObject {
  func exists(_ url: URL) -> Bool
  /// To the Trash, so an older copy can be recovered.
  func trash(_ url: URL) throws
  func copy(_ from: URL, to: URL) throws
  /// Opens the copy and quits this one.
  func openAndQuit(_ url: URL)
}

public enum MoveOutcome: Equatable, Sendable {
  case opened(path: String)
  case failed(String)
}

/// From a disk image or a translocated path, Offload is copied into Applications (a disk image is read-only, so it is
/// a copy, as Finder does). An older Offload already there goes to the Trash first, so the person runs this version.
/// Any failure leaves things as they were and says what to do instead.
@MainActor
public enum AppMover {
  public static func move(source: URL, applications: URL, ops: AppFileOps) -> MoveOutcome {
    let destination = applications.appendingPathComponent(source.lastPathComponent)
    do {
      if ops.exists(destination) { try ops.trash(destination) }
      try ops.copy(source, to: destination)
    } catch {
      return .failed(OnboardingCopy.moveFailed)
    }
    ops.openAndQuit(destination)
    return .opened(path: destination.path)
  }
}

/// The real file steps. Constructed only by the app.
@MainActor
public final class LiveAppFileOps: AppFileOps {
  public init() {}
  public func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
  public func trash(_ url: URL) throws { try FileManager.default.trashItem(at: url, resultingItemURL: nil) }
  public func copy(_ from: URL, to: URL) throws { try FileManager.default.copyItem(at: from, to: to) }
  public func openAndQuit(_ url: URL) {
    let config = NSWorkspace.OpenConfiguration()
    config.createsNewApplicationInstance = true
    NSWorkspace.shared.openApplication(at: url, configuration: config) { _, error in
      let ok = error == nil
      Task { @MainActor in
        if ok { NSApp.terminate(nil) }
      }
    }
  }
}
