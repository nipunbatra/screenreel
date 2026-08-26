import Foundation
import ProjectModel

/// Shortcut-overlay evaluation: which key chips are on screen at a source
/// time. SHORTCUTS ONLY by design — plain typing never renders, so the
/// overlay cannot spell out what was typed even when keystroke capture is
/// on. Pure and deterministic; preview and export share it.
public enum KeystrokeChips {

    public struct Chip: Equatable, Sendable {
        public let label: String
        /// 0 at the press → 1 when fully faded.
        public let progress: Double
    }

    public static let defaultDurationNs: Int64 = 1_400_000_000
    public static let maxVisible = 3

    /// A press renders when it carries a chording modifier (⌘⌃⌥) or is a
    /// standalone special key (F-keys, escape). Shift alone is typing, and
    /// fn alone does NOT qualify: macOS sets the fn flag on arrows and
    /// Home/End/PgUp/PgDn, which would flood the overlay during ordinary
    /// caret movement.
    public static func isShortcut(_ press: MotionTimeline.KeyPress) -> Bool {
        let chording: Set<EventModifier> = [.command, .control, .option]
        if press.modifiers.contains(where: { chording.contains($0) }) {
            return true
        }
        return standaloneKeys.contains(press.keyCode)
    }

    public static func chips(
        presses: [MotionTimeline.KeyPress],
        atSource timeNs: Int64,
        durationNs: Int64 = defaultDurationNs
    ) -> [Chip] {
        guard durationNs > 0, !presses.isEmpty else { return [] }
        let windowStart = timeNs - durationNs
        var low = 0
        var high = presses.count
        while low < high {
            let mid = (low + high) / 2
            if presses[mid].timeNs <= windowStart { low = mid + 1 } else { high = mid }
        }
        var result: [Chip] = []
        for press in presses[low...] {
            guard press.timeNs <= timeNs else { break }
            guard isShortcut(press) else { continue }
            result.append(Chip(
                label: label(for: press),
                progress: Double(timeNs - press.timeNs) / Double(durationNs)))
        }
        return Array(result.suffix(maxVisible))
    }

    /// "⌃⌥⇧⌘" + key, in Apple HIG modifier order.
    public static func label(for press: MotionTimeline.KeyPress) -> String {
        var text = ""
        if press.modifiers.contains(.control) { text += "⌃" }
        if press.modifiers.contains(.option) { text += "⌥" }
        if press.modifiers.contains(.shift) { text += "⇧" }
        if press.modifiers.contains(.command) { text += "⌘" }
        text += keyLabel(press.keyCode)
        return text
    }

    /// Standalone keys that chip without a modifier.
    static let standaloneKeys: Set<Int> = [
        53,  // escape
        122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111,  // F1-F12
    ]

    /// ANSI virtual keycodes → display labels (Carbon HIToolbox values).
    public static func keyLabel(_ keyCode: Int) -> String {
        switch keyCode {
        case 0: return "A"
        case 1: return "S"
        case 2: return "D"
        case 3: return "F"
        case 4: return "H"
        case 5: return "G"
        case 6: return "Z"
        case 7: return "X"
        case 8: return "C"
        case 9: return "V"
        case 11: return "B"
        case 12: return "Q"
        case 13: return "W"
        case 14: return "E"
        case 15: return "R"
        case 16: return "Y"
        case 17: return "T"
        case 18: return "1"
        case 19: return "2"
        case 20: return "3"
        case 21: return "4"
        case 22: return "6"
        case 23: return "5"
        case 24: return "="
        case 25: return "9"
        case 26: return "7"
        case 27: return "-"
        case 28: return "8"
        case 29: return "0"
        case 30: return "]"
        case 31: return "O"
        case 32: return "U"
        case 33: return "["
        case 34: return "I"
        case 35: return "P"
        case 36: return "↩"
        case 37: return "L"
        case 38: return "J"
        case 39: return "'"
        case 40: return "K"
        case 41: return ";"
        case 42: return "\\"
        case 43: return ","
        case 44: return "/"
        case 45: return "N"
        case 46: return "M"
        case 47: return "."
        case 48: return "⇥"
        case 49: return "Space"
        case 50: return "`"
        case 51: return "⌫"
        case 53: return "⎋"
        case 96: return "F5"
        case 97: return "F6"
        case 98: return "F7"
        case 99: return "F3"
        case 100: return "F8"
        case 101: return "F9"
        case 103: return "F11"
        case 109: return "F10"
        case 111: return "F12"
        case 115: return "↖"
        case 116: return "⇞"
        case 117: return "⌦"
        case 118: return "F4"
        case 119: return "↘"
        case 120: return "F2"
        case 121: return "⇟"
        case 122: return "F1"
        case 123: return "←"
        case 124: return "→"
        case 125: return "↓"
        case 126: return "↑"
        default: return "key\(keyCode)"
        }
    }
}
