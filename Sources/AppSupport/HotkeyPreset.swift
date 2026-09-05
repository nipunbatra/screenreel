import Foundation

/// The three things a global shortcut can do. The raw value is the Carbon
/// hot-key ID the app registers, so it must stay stable.
public enum HotkeyAction: UInt32, CaseIterable, Sendable, Identifiable {
    case toggleRecording = 1
    case togglePause = 2
    case recordArea = 3

    public var id: UInt32 { rawValue }

    public var title: String {
        switch self {
        case .toggleRecording: return "Start / stop recording"
        case .togglePause: return "Pause / resume"
        case .recordArea: return "Record an area"
        }
    }

    /// The preset each action ships with.
    public var defaultPreset: HotkeyPreset {
        switch self {
        case .toggleRecording: return .commandShiftR
        case .togglePause: return .commandShiftP
        case .recordArea: return .commandShiftA
        }
    }

    /// The UserDefaults key the preset is stored under.
    public var preferenceKey: String {
        switch self {
        case .toggleRecording: return "hotkey.toggleRecording"
        case .togglePause: return "hotkey.togglePause"
        case .recordArea: return "hotkey.recordArea"
        }
    }
}

/// Carbon modifier bits (`cmdKey`, `shiftKey`, `optionKey`, `controlKey`)
/// as an OptionSet. Kept here — without importing Carbon — so the mapping
/// is unit-testable; the app layer feeds `rawValue` to RegisterEventHotKey.
public struct CarbonModifiers: OptionSet, Hashable, Sendable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let command = CarbonModifiers(rawValue: 0x0100)
    public static let shift = CarbonModifiers(rawValue: 0x0200)
    public static let option = CarbonModifiers(rawValue: 0x0800)
    public static let control = CarbonModifiers(rawValue: 0x1000)

    /// Glyphs in the order macOS menus draw them: ⌃ ⌥ ⇧ ⌘.
    public var glyphs: String {
        var out = ""
        if contains(.control) { out += "⌃" }
        if contains(.option) { out += "⌥" }
        if contains(.shift) { out += "⇧" }
        if contains(.command) { out += "⌘" }
        return out
    }
}

/// One concrete key chord: a Carbon virtual key code plus modifiers.
public struct KeyCombo: Hashable, Sendable {
    /// Carbon virtual key code (`kVK_ANSI_R` = 15, …).
    public let keyCode: UInt32
    public let modifiers: CarbonModifiers
    /// The key's printable form for menus ("R", "1").
    public let keyLabel: String

    public init(keyCode: UInt32, modifiers: CarbonModifiers, keyLabel: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.keyLabel = keyLabel
    }

    /// "⌘⇧R" — what the Settings picker and menu show.
    public var display: String { modifiers.glyphs + keyLabel }

    /// Lower-case key equivalent for an NSMenuItem ("r").
    public var keyEquivalent: String { keyLabel.lowercased() }
}

/// Virtual key codes for the letters/digits the presets use (ANSI layout,
/// `Carbon/HIToolbox/Events.h`). Tests assert these against the SDK.
public enum VirtualKey {
    public static let a: UInt32 = 0x00
    public static let r: UInt32 = 0x0F
    public static let p: UInt32 = 0x23
    public static let one: UInt32 = 0x12
    public static let two: UInt32 = 0x13
    public static let three: UInt32 = 0x14
}

/// A small, curated set of chords the user can pick per action. Curated
/// rather than free-form so nothing collides with a system shortcut and
/// the picker stays a one-click choice.
public enum HotkeyPreset: String, CaseIterable, Sendable, Identifiable, Codable {
    case off
    case commandShiftR
    case commandShiftP
    case commandShiftA
    case commandShift1
    case commandShift2
    case commandShift3
    case controlOptionR
    case controlOptionP
    case controlOptionA
    case controlOptionCommandR
    case controlOptionCommandP
    case controlOptionCommandA

    public var id: String { rawValue }

    /// nil for `.off`.
    public var combo: KeyCombo? {
        switch self {
        case .off: return nil
        case .commandShiftR:
            return KeyCombo(keyCode: VirtualKey.r, modifiers: [.command, .shift], keyLabel: "R")
        case .commandShiftP:
            return KeyCombo(keyCode: VirtualKey.p, modifiers: [.command, .shift], keyLabel: "P")
        case .commandShiftA:
            return KeyCombo(keyCode: VirtualKey.a, modifiers: [.command, .shift], keyLabel: "A")
        case .commandShift1:
            return KeyCombo(keyCode: VirtualKey.one, modifiers: [.command, .shift], keyLabel: "1")
        case .commandShift2:
            return KeyCombo(keyCode: VirtualKey.two, modifiers: [.command, .shift], keyLabel: "2")
        case .commandShift3:
            return KeyCombo(keyCode: VirtualKey.three, modifiers: [.command, .shift], keyLabel: "3")
        case .controlOptionR:
            return KeyCombo(keyCode: VirtualKey.r, modifiers: [.control, .option], keyLabel: "R")
        case .controlOptionP:
            return KeyCombo(keyCode: VirtualKey.p, modifiers: [.control, .option], keyLabel: "P")
        case .controlOptionA:
            return KeyCombo(keyCode: VirtualKey.a, modifiers: [.control, .option], keyLabel: "A")
        case .controlOptionCommandR:
            return KeyCombo(
                keyCode: VirtualKey.r, modifiers: [.control, .option, .command], keyLabel: "R")
        case .controlOptionCommandP:
            return KeyCombo(
                keyCode: VirtualKey.p, modifiers: [.control, .option, .command], keyLabel: "P")
        case .controlOptionCommandA:
            return KeyCombo(
                keyCode: VirtualKey.a, modifiers: [.control, .option, .command], keyLabel: "A")
        }
    }

    /// "Off" or the chord glyphs.
    public var label: String { combo?.display ?? "Off" }

    /// The preset that registers a given chord, if any.
    public static func matching(_ combo: KeyCombo) -> HotkeyPreset? {
        allCases.first { $0.combo == combo }
    }
}
