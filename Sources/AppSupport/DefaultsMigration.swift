import Foundation

/// One-time copy of user defaults from the bundle identifier the app had
/// before the rename (`in.aks.app`) into the current domain. Without it a
/// user who updates loses the license key, hotkey presets, menu-bar and
/// countdown settings, the recordings folder, and the update-check state,
/// because `UserDefaults.standard` is a fresh domain under the new id.
public enum DefaultsMigration {
    public static let legacySuiteName = "in.aks.app"
    public static let markerKey = "migration.defaultsFromAks"

    /// Keys the old app stored that mean the same thing today. Window
    /// frames and other AppKit bookkeeping are deliberately left behind.
    public static let carriedPrefixes = ["license.", "updates.", "preferences.", "hotkeys.", "screenshots."]

    @discardableResult
    public static func migrateIfNeeded(
        into target: UserDefaults = .standard,
        legacyDomain: String? = legacySuiteName
    ) -> [String] {
        guard target.object(forKey: markerKey) == nil else { return [] }
        var copied: [String] = []
        if let legacyDomain {
            // persistentDomain(forName:) is the raw plist contents of that
            // domain only — not the global/registration layers.
            let contents = target.persistentDomain(forName: legacyDomain) ?? [:]
            for (key, value) in contents where carriedPrefixes.contains(where: { key.hasPrefix($0) }) {
                if target.object(forKey: key) == nil {
                    target.set(value, forKey: key)
                    copied.append(key)
                }
            }
        }
        target.set(true, forKey: markerKey)
        return copied.sorted()
    }
}
