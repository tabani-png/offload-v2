import AppKit

/// The file steps of screen 0's "Move and reopen", behind a protocol so the decision is tested without touching disk.
@MainActor
public protocol AppFileOps: AnyObject {
  func exists(_ url: URL) -> Bool
  func copy(_ from: URL, to: URL) throws
  /// Replaces `destination` with `item` in one step (`FileManager.replaceItemAt`); the original stays on failure.
  func replace(_ destination: URL, with item: URL) throws
  func move(_ from: URL, to: URL) throws
  func remove(_ url: URL) throws
  /// Clears `com.apple.quarantine`, so Gatekeeper does not translocate the moved copy again (as LetsMove does). The
  /// person already opened this copy, which is when Gatekeeper checked it.
  func clearQuarantine(_ url: URL)
  /// Opens the copy and quits this one.
  func openAndQuit(_ url: URL)
}

public enum MoveOutcome: Equatable, Sendable {
  case opened(path: String)
  case failed(String)
}

/// From a disk image or a translocated path, Offload is copied into Applications (a disk image is read-only, so it is
/// a copy, as Finder does). The copy is made beside the destination first and then swapped in, so any failure leaves
/// Applications as it was (an older Offload there stays until the new one is complete) and says what to do instead.
@MainActor
public enum AppMover {
  public static func move(source: URL, applications: URL, ops: AppFileOps) -> MoveOutcome {
    let name = source.lastPathComponent
    let destination = applications.appendingPathComponent(name)
    let staging = applications.appendingPathComponent(".\(name).moving")
    if ops.exists(staging) { try? ops.remove(staging) }
    do {
      try ops.copy(source, to: staging)
      if ops.exists(destination) {
        try ops.replace(destination, with: staging)
      } else {
        try ops.move(staging, to: destination)
      }
    } catch {
      try? ops.remove(staging)
      return .failed(OnboardingCopy.moveFailed)
    }
    ops.clearQuarantine(destination)
    ops.openAndQuit(destination)
    return .opened(path: destination.path)
  }
}

/// The real file steps. Constructed only by the app.
@MainActor
public final class LiveAppFileOps: AppFileOps {
  public init() {}
  public func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
  public func copy(_ from: URL, to: URL) throws { try FileManager.default.copyItem(at: from, to: to) }
  public func replace(_ destination: URL, with item: URL) throws {
    _ = try FileManager.default.replaceItemAt(destination, withItemAt: item)
  }
  public func move(_ from: URL, to: URL) throws { try FileManager.default.moveItem(at: from, to: to) }
  public func remove(_ url: URL) throws { try FileManager.default.removeItem(at: url) }
  public func clearQuarantine(_ url: URL) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
    p.arguments = ["-dr", "com.apple.quarantine", url.path]
    do {
      try p.run()
      p.waitUntilExit()
    } catch {
      // Not fatal: at worst macOS asks to move it again.
    }
  }
  public func openAndQuit(_ url: URL) {
    let config = NSWorkspace.OpenConfiguration()
    config.createsNewApplicationInstance = true
    // @Sendable: AppKit calls this on a background queue; it hops to the main actor itself.
    NSWorkspace.shared.openApplication(at: url, configuration: config) { @Sendable _, error in
      let ok = error == nil
      Task { @MainActor in
        if ok { NSApp.terminate(nil) }
      }
    }
  }
}
