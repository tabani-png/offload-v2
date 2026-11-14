// Which appcast channels this Mac is offered (docs/DEPLOYMENT.md section 4, Channels).

/// Tester items carry `sparkle:channel` "beta"; the default channel is always offered.
enum UpdateChannels {
    /// Settings key of "Get early builds".
    static let getEarlyBuildsKey = "getEarlyBuilds"
    static let beta = "beta"

    /// ["beta"] only when "Get early builds" is on; otherwise only the default channel.
    static func allowedChannels(getEarlyBuilds: Bool) -> Set<String> {
        getEarlyBuilds ? [beta] : []
    }

    /// Reads "Get early builds" from settings.
    static func allowedChannels(settings: any SettingsStore) -> Set<String> {
        allowedChannels(getEarlyBuilds: settings.bool(forKey: getEarlyBuildsKey))
    }
}
