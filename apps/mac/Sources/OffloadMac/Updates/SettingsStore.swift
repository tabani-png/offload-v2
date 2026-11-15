// The few boolean settings the updater reads and writes. UserDefaults in the app; an in-memory store in the
// self-check, so `Offload --self-check` writes nothing to disk.
import Foundation

/// Boolean key-value settings.
protocol SettingsStore: AnyObject {
    func bool(forKey key: String) -> Bool
    func set(_ value: Bool, forKey key: String)
    func removeObject(forKey key: String)
}

extension UserDefaults: SettingsStore {}

/// Settings kept in memory only, gone when the process ends.
final class MemorySettingsStore: SettingsStore {
    private var values: [String: Bool] = [:]

    init() {}

    func bool(forKey key: String) -> Bool { values[key] ?? false }
    func set(_ value: Bool, forKey key: String) { values[key] = value }
    func removeObject(forKey key: String) { values.removeValue(forKey: key) }
}
