// Whether this build may update itself, read from its Info.plist (docs/DEPLOYMENT.md sections 3.2 and 4).
// bundle.sh leaves the feed keys out when OFFLOAD_DOWNLOADS_HOST or SPARKLE_ED_PUBLIC_KEY is absent; such a build
// never starts Sparkle.
import Foundation

/// The Sparkle feed settings of one build.
struct UpdateFeedConfig: Sendable, Equatable {
    static let offStatus = "updates off in this build"
    static let onStatus = "updates on"

    /// True only for a signed https feed with a public EdDSA key and verification before extraction.
    let isEnabled: Bool

    /// One plain line for the menu and the self-check.
    var statusLine: String { isEnabled ? Self.onStatus : Self.offStatus }

    init(info: [String: Any]) {
        isEnabled = Self.isHTTPSWithHost(info["SUFeedURL"])
            && Self.isNonEmptyString(info["SUPublicEDKey"])
            && Self.isTrue(info["SURequireSignedFeed"])
            && Self.isTrue(info["SUVerifyUpdateBeforeExtraction"])
    }

    private static func isHTTPSWithHost(_ value: Any?) -> Bool {
        guard let text = value as? String, let parts = URLComponents(string: text) else { return false }
        guard parts.scheme == "https", let host = parts.host else { return false }
        return !host.isEmpty
    }

    private static func isNonEmptyString(_ value: Any?) -> Bool {
        guard let text = value as? String else { return false }
        return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Plist true in any of its forms: a boolean, a number, or "YES" / "true" / "1".
    private static func isTrue(_ value: Any?) -> Bool {
        guard let value else { return false }
        switch value {
        case let flag as Bool: return flag
        case let number as NSNumber: return number.boolValue
        case let text as String: return ["yes", "true", "1"].contains(text.lowercased())
        default: return false
        }
    }
}
