// Where this Mac may send (slice m3-14-mac-app-integration). `.local` is the test build's default: nothing leaves the
// Mac. `.cloud` needs an API base, an enrolled device id and the device key that enrollment made; only then does an
// upload runtime exist at all. m3-10 reads the same value (AppComposition.backend) to choose its data source.
import Foundation
import OffloadStore
import OffloadUploader

public enum BackendMode: Equatable, Sendable {
  case local
  case cloud(apiBase: URL, deviceID: String)

  /// Info.plist key of the API base. The test build does not set it.
  public static let apiBaseInfoKey = "OffloadAPIBase"
  /// `UserDefaults` key of this Mac's device id, written by enrollment (m1-04's device flow, PR #13's client).
  public static let deviceIDDefaultsKey = "OffloadDeviceID"

  public var allowsUploads: Bool {
    if case .cloud = self { return true }
    return false
  }

  /// `.cloud` only with an `https` API base (or `http` on a loopback host, for a local server), a non-empty device id
  /// and a stored device key; anything else is `.local`.
  public static func decide(apiBase: String?, deviceID: String?, deviceKeyStored: Bool) -> BackendMode {
    guard let raw = apiBase?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty,
      let url = URL(string: raw), let scheme = url.scheme?.lowercased(),
      let host = url.host?.lowercased(), !host.isEmpty
    else { return .local }
    let loopback = host == "localhost" || host == "127.0.0.1" || host == "::1"
    guard scheme == "https" || (scheme == "http" && loopback) else { return .local }
    guard let id = deviceID?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty, deviceKeyStored else {
      return .local
    }
    return .cloud(apiBase: url, deviceID: id)
  }

  /// The live values. The Keychain is read only when an API base and a device id are both set, so the test build
  /// never touches it here.
  public static func live(info: [String: Any]?, defaults: UserDefaults = .standard, secrets: any SecretStore) -> BackendMode {
    let api = info?[apiBaseInfoKey] as? String
    let device = defaults.string(forKey: deviceIDDefaultsKey)
    guard decide(apiBase: api, deviceID: device, deviceKeyStored: true) != .local else { return .local }
    return decide(apiBase: api, deviceID: device, deviceKeyStored: DeviceKey.isStored(secrets: secrets))
  }
}
