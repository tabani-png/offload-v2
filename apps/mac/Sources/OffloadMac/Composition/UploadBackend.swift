// Whether this Mac may upload at all (slice m3-14-mac-app-integration): an enrolled device with an API to send to.
// `.local` is the test build's default: no upload runtime exists, nothing can leave the Mac. `.cloud` needs an API
// base, an enrolled device id and the device key that enrollment made.
//
// This is not what the screens read. m3-10's `BackendMode` (Backend/BackendMode.swift on the sibling branches) decides
// where Today, Weekly review and Build progress get their data (a member token); this decides whether the uploader
// exists (a device key). Both read the API base from the same setting, `ai.offload.api.baseURL`, with the same https
// rule, so one place says where the API is (review 4, finding 1; SPEC Scope changes).
import Foundation
import OffloadStore
import OffloadUploader

public enum UploadBackend: Equatable, Sendable {
  case local
  case cloud(apiBase: URL, deviceID: String)

  /// `UserDefaults` key of the API base, shared with m3-10's `BackendMode.baseURLDefaultsKey`. The test build sets none.
  public static let baseURLDefaultsKey = "ai.offload.api.baseURL"
  /// `UserDefaults` key of this Mac's device id, written by enrollment (m1-04's device flow, PR #13's client).
  public static let deviceIDDefaultsKey = "OffloadDeviceID"

  public var allowsUploads: Bool {
    if case .cloud = self { return true }
    return false
  }

  /// `.cloud` only with an `https` API base with a host (no user, password, query or fragment; m3-10's rule), a
  /// non-empty device id and a stored device key; anything else is `.local`.
  public static func decide(apiBase: String?, deviceID: String?, deviceKeyStored: Bool) -> UploadBackend {
    guard let url = validatedBaseURL(apiBase) else { return .local }
    guard let id = deviceID?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty, deviceKeyStored else {
      return .local
    }
    return .cloud(apiBase: url, deviceID: id)
  }

  /// The base URL when `raw` is acceptable as the API base, else nil.
  public static func validatedBaseURL(_ raw: String?) -> URL? {
    guard let raw else { return nil }
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, let comps = URLComponents(string: trimmed) else { return nil }
    guard comps.scheme?.lowercased() == "https" else { return nil }
    guard let host = comps.host, !host.isEmpty else { return nil }
    guard comps.user == nil, comps.password == nil, comps.query == nil, comps.fragment == nil else { return nil }
    return comps.url
  }

  /// The live values. The Keychain is read only when an API base and a device id are both set, so the test build
  /// never touches it here.
  public static func live(defaults: UserDefaults = .standard, secrets: any SecretStore) -> UploadBackend {
    let api = defaults.string(forKey: baseURLDefaultsKey)
    let device = defaults.string(forKey: deviceIDDefaultsKey)
    guard decide(apiBase: api, deviceID: device, deviceKeyStored: true) != .local else { return .local }
    return decide(apiBase: api, deviceID: device, deviceKeyStored: DeviceKey.isStored(secrets: secrets))
  }
}
