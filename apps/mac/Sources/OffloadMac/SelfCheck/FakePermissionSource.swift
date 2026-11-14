// The permission source `Offload --self-check` runs against, so the installed-copy smoke test needs no real grants.
// Part of the product's self-check, not test-only.

/// Answers from fixed values; both permissions granted by default.
@MainActor
final class FakePermissionSource: PermissionSource {
    private let granted: [Permission: Bool]

    init(accessibility: Bool = true, screenRecording: Bool = true) {
        granted = [.accessibility: accessibility, .screenRecording: screenRecording]
    }

    func isGranted(_ permission: Permission) -> Bool { granted[permission] ?? false }
}
