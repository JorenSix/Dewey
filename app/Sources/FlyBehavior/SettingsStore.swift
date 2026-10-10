import Foundation
import FlyCore

/// Persists `DeweySettings` as a JSON string in UserDefaults under the key `"settings"`
/// (e.g. `{"friends":0,"restlessness":0.5,"size":40,"visible":true}`; readable with `defaults read <bundle id> settings`).
/// Values are clamped on load and save; a missing or unreadable entry yields the defaults.
/// Lives in FlyBehavior (not FlyApp) so it can be unit-tested with `UserDefaults(suiteName:)`.
public final class SettingsStore {
    public static let key = "settings"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Size clamped to `DeweySettings.sizeRange`, restlessness to 0...1, friends to
    /// `DeweySettings.friendsRange`; non-finite values → defaults.
    public static func clamped(_ s: DeweySettings) -> DeweySettings {
        let d = DeweySettings()
        var c = s
        c.size = s.size.isFinite ? min(max(s.size, DeweySettings.sizeRange.lowerBound), DeweySettings.sizeRange.upperBound) : d.size
        c.restlessness = s.restlessness.isFinite ? min(max(s.restlessness, 0), 1) : d.restlessness
        c.friends = min(max(s.friends, DeweySettings.friendsRange.lowerBound), DeweySettings.friendsRange.upperBound)
        return c
    }

    public func load() -> DeweySettings {
        let data: Data?
        if let str = defaults.string(forKey: SettingsStore.key) {
            data = str.data(using: .utf8)
        } else {
            data = defaults.data(forKey: SettingsStore.key)
        }
        guard let data, let s = try? JSONDecoder().decode(DeweySettings.self, from: data) else {
            return DeweySettings()
        }
        return SettingsStore.clamped(s)
    }

    public func save(_ s: DeweySettings) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        guard let data = try? enc.encode(SettingsStore.clamped(s)), let str = String(data: data, encoding: .utf8) else { return }
        defaults.set(str, forKey: SettingsStore.key)
    }

    /// One-time migration: if no settings exist yet, copy them from a legacy defaults domain
    /// (`be.ugent.ghentcdh.dewey`, the pre-v3 bundle id). Copies only; the legacy entry is never deleted.
    @discardableResult
    public func migrate(from legacy: UserDefaults?) -> Bool {
        guard defaults.object(forKey: SettingsStore.key) == nil, let legacy,
              let old = legacy.object(forKey: SettingsStore.key) else { return false }
        defaults.set(old, forKey: SettingsStore.key)
        return true
    }

    public static let legacyDomain = "be.ugent.ghentcdh.dewey"

    public func reset() { defaults.removeObject(forKey: SettingsStore.key) }
}
