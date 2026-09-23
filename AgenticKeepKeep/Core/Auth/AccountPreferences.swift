import Foundation

/// Namespaced snapshots keep persona notes and usage from crossing account boundaries.
struct AccountPreferences {
    let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    private let activeKey = "auth.preferences.active"
    private let legacyKey = "auth.preferences.legacy"
    private let keys = ["milo.style", "milo.name", "milo.preference", "healthkit.lastSync",
                        "llm.usage.promptTokens", "llm.usage.completionTokens", "llm.usage.callCount"]
    private func snapshot() -> [String: Any] {
        Dictionary(uniqueKeysWithValues: keys.compactMap { key in defaults.object(forKey: key).map { (key, $0) } })
    }
    func deactivate() {
        if let account = defaults.string(forKey: activeKey) {
            defaults.set(snapshot(), forKey: "auth.preferences." + account)
        } else if defaults.dictionary(forKey: legacyKey) == nil {
            defaults.set(snapshot(), forKey: legacyKey)
        }
        keys.forEach { defaults.removeObject(forKey: $0) }
        defaults.removeObject(forKey: activeKey)
    }
    func activate(_ account: String, adoptingLegacy: Bool) {
        if defaults.string(forKey: activeKey) == account { return }
        deactivate()
        let values = defaults.dictionary(forKey: "auth.preferences." + account)
            ?? (adoptingLegacy ? defaults.dictionary(forKey: legacyKey) : nil) ?? [:]
        for (key, value) in values where keys.contains(key) { defaults.set(value, forKey: key) }
        defaults.set(account, forKey: activeKey)
    }
}
