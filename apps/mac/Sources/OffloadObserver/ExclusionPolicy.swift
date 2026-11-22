// Exclusions (ARCHITECTURE section 1, DATA_MODEL `exclusions`): windows Offload never watches. The built-in list is the
// same file the server uses (packages/masking/src/exclusions.builtin.json, bundled as BuiltinExclusionsJSON); the
// member's own "Never watch" rows are added to it and reloaded every 2 seconds. An excluded window yields the app
// name only: no title, host, document or text.
import Foundation
import OffloadContracts

public struct ExclusionRule: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case bundleID = "bundle_id"
        case host
        case titleContains = "title_contains"
    }

    public var kind: Kind
    public var value: String

    public init(kind: Kind, value: String) {
        self.kind = kind
        self.value = value
    }
}

public struct ExclusionPolicy: Equatable, Sendable {
    public var rules: [ExclusionRule]

    public init(rules: [ExclusionRule]) { self.rules = rules }

    /// The shared built-in list.
    public static let builtin: ExclusionPolicy = {
        let rules = (try? JSONDecoder().decode([ExclusionRule].self, from: Data(BuiltinExclusionsJSON.text.utf8))) ?? []
        return ExclusionPolicy(rules: rules)
    }()

    /// The first rule the window matches, or nil. Same rules as the server (`matchExclusion`): `host` is exact or a
    /// dot-suffix and case-insensitive (`bank.example` matches `www.bank.example`, not `notbank.example`), `bundle_id` is
    /// exact, `title_contains` is a case-insensitive substring.
    public func evaluate(_ snapshot: FocusSnapshot) -> ExclusionRule? {
        let host = snapshot.url.flatMap { URLComponents(string: $0.trimmingCharacters(in: .whitespacesAndNewlines))?.host }?.lowercased()
        let title = snapshot.windowTitle.lowercased()
        for rule in rules {
            let value = rule.value.lowercased()
            if value.isEmpty { continue }
            switch rule.kind {
            case .host:
                if let host, host == value || host.hasSuffix("." + value) { return rule }
            case .bundleID:
                if snapshot.bundleID == rule.value { return rule }
            case .titleContains:
                if title.contains(value) { return rule }
            }
        }
        // The glue knows about a private window even when its title does not say so.
        if snapshot.isPrivateBrowsing { return ExclusionRule(kind: .titleContains, value: "private browsing") }
        return nil
    }
}

/// Built-in rules plus the member's file, re-read at most every 2 seconds.
@MainActor public final class ExclusionReloader {
    public static let interval: TimeInterval = 2

    private let file: URL
    private let time: any TimeSource
    private var lastLoad: Date?
    private var current: ExclusionPolicy

    public init(file: URL, time: any TimeSource) {
        self.file = file
        self.time = time
        current = .builtin
    }

    public func policy(now: Date) -> ExclusionPolicy {
        if let last = lastLoad, now.timeIntervalSince(last) < Self.interval { return current }
        lastLoad = now
        var user: [ExclusionRule] = []
        if let data = try? Data(contentsOf: file) {
            // An unreadable file keeps the previous member rules rather than dropping them.
            guard let rules = try? JSONDecoder().decode([ExclusionRule].self, from: data) else { return current }
            user = rules
        }
        current = ExclusionPolicy(rules: ExclusionPolicy.builtin.rules + user)
        return current
    }
}
