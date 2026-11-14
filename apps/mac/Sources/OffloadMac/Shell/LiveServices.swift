import AppKit
import ServiceManagement

// AppKit-backed services the app constructs at launch. Tests never construct these.

/// "Open Offload when I log in" (`SMAppService`). A `swift build` binary is not a bundle, so registering can fail;
/// that is ignored and setup goes on.
@MainActor
public final class LiveLoginItem: LoginItemService {
  public init() {}
  public func setEnabled(_ on: Bool) {
    do {
      if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    } catch {
      // Not a signed bundle, or the person turned it off in System Settings: nothing to do here.
    }
  }
}

/// Quits and reopens Offload after the Screen Recording grant. The onboarding state is already saved.
@MainActor
public final class LiveRelauncher: Relauncher {
  public init() {}
  public func relaunch() {
    let url = Bundle.main.bundleURL
    guard url.pathExtension == "app" else {
      NSApp.terminate(nil)
      return
    }
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

/// Shows the sample week window.
@MainActor
public final class SampleWeekFlag: ObservableObject, SampleWeekPresenter {
  @Published public var showing = false
  public init() {}
  public func show() { showing = true }
}

/// Resolves a typed app name ("Slack") to its bundle id from the installed apps, without guessing.
public enum InstalledApps {
  public static func bundleID(forName name: String, fileManager: FileManager = .default) -> String? {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, !trimmed.contains("/") else { return nil }
    let home = fileManager.homeDirectoryForCurrentUser.path
    for dir in ["/Applications", "/System/Applications", home + "/Applications"] {
      let url = URL(fileURLWithPath: dir).appendingPathComponent(trimmed + ".app")
      if fileManager.fileExists(atPath: url.path), let id = Bundle(url: url)?.bundleIdentifier { return id }
    }
    return nil
  }
}
