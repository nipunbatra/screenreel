import Foundation

/// Everything the Settings window edits, with the defaults a fresh
/// install gets. A plain value: the app owns one, mutates it, and hands it
/// to `PreferencesStore` to persist.
public struct Preferences: Equatable, Sendable {
    /// Keep the status item in the menu bar even while idle.
    public var showInMenuBar: Bool = true
    /// Seconds between "record" and the first captured frame; one of
    /// `countdownChoices`.
    public var countdownSeconds: Int = 3
    /// After Stop: open the recording in the editor (true) or land on the
    /// start screen with it listed first (false).
    public var openEditorAfterRecording: Bool = true
    /// Absolute path of the recordings folder; nil = the default
    /// (~/Movies/Screenreel). The app falls back to the default when the folder
    /// no longer exists.
    public var recordingsFolderPath: String? = nil
    public var hotkeys: [HotkeyAction: HotkeyPreset] = Preferences.defaultHotkeys

    public static let countdownChoices: [Int] = [0, 3, 5]
    public static let defaultCountdownSeconds = 3

    public static var defaultHotkeys: [HotkeyAction: HotkeyPreset] {
        Dictionary(uniqueKeysWithValues: HotkeyAction.allCases.map { ($0, $0.defaultPreset) })
    }

    public init() {}

    public func hotkey(for action: HotkeyAction) -> HotkeyPreset {
        hotkeys[action] ?? action.defaultPreset
    }

    /// Bind a chord to an action. A chord can drive only one action, so
    /// any other action holding the same (non-off) preset is switched off
    /// rather than silently double-registered.
    public mutating func assign(_ preset: HotkeyPreset, to action: HotkeyAction) {
        if preset != .off {
            for other in HotkeyAction.allCases where other != action && hotkeys[other] == preset {
                hotkeys[other] = .off
            }
        }
        hotkeys[action] = preset
    }

    /// Clamp values that may have been hand-edited in defaults into the
    /// supported set.
    public func sanitized() -> Preferences {
        var copy = self
        if !Preferences.countdownChoices.contains(copy.countdownSeconds) {
            copy.countdownSeconds = Preferences.defaultCountdownSeconds
        }
        for action in HotkeyAction.allCases where copy.hotkeys[action] == nil {
            copy.hotkeys[action] = action.defaultPreset
        }
        if let path = copy.recordingsFolderPath, path.isEmpty {
            copy.recordingsFolderPath = nil
        }
        return copy
    }
}

/// UserDefaults persistence for `Preferences`: one key per setting so a
/// missing key means "default" and old builds ignore keys they don't know.
public struct PreferencesStore {
    public enum Key {
        public static let showInMenuBar = "showInMenuBar"
        public static let countdownSeconds = "countdownSeconds"
        public static let openEditorAfterRecording = "openEditorAfterRecording"
        public static let recordingsFolderPath = "recordingsFolderPath"
    }

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> Preferences {
        var prefs = Preferences()
        if defaults.object(forKey: Key.showInMenuBar) != nil {
            prefs.showInMenuBar = defaults.bool(forKey: Key.showInMenuBar)
        }
        if defaults.object(forKey: Key.countdownSeconds) != nil {
            prefs.countdownSeconds = defaults.integer(forKey: Key.countdownSeconds)
        }
        if defaults.object(forKey: Key.openEditorAfterRecording) != nil {
            prefs.openEditorAfterRecording = defaults.bool(forKey: Key.openEditorAfterRecording)
        }
        prefs.recordingsFolderPath = defaults.string(forKey: Key.recordingsFolderPath)
        for action in HotkeyAction.allCases {
            if let raw = defaults.string(forKey: action.preferenceKey),
                let preset = HotkeyPreset(rawValue: raw)
            {
                prefs.hotkeys[action] = preset
            }
        }
        return prefs.sanitized()
    }

    public func save(_ prefs: Preferences) {
        defaults.set(prefs.showInMenuBar, forKey: Key.showInMenuBar)
        defaults.set(prefs.countdownSeconds, forKey: Key.countdownSeconds)
        defaults.set(prefs.openEditorAfterRecording, forKey: Key.openEditorAfterRecording)
        if let path = prefs.recordingsFolderPath {
            defaults.set(path, forKey: Key.recordingsFolderPath)
        } else {
            defaults.removeObject(forKey: Key.recordingsFolderPath)
        }
        for action in HotkeyAction.allCases {
            defaults.set(prefs.hotkey(for: action).rawValue, forKey: action.preferenceKey)
        }
    }
}
