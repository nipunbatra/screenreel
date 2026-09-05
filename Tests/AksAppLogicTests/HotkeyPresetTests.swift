import Carbon.HIToolbox
import XCTest

@testable import AppSupport

/// The preset table must agree with the Carbon constants the app hands to
/// RegisterEventHotKey; a wrong key code here means a shortcut that fires
/// the wrong key (or never).
final class HotkeyPresetTests: XCTestCase {

    func testModifierBitsMatchCarbon() {
        XCTAssertEqual(CarbonModifiers.command.rawValue, UInt32(cmdKey))
        XCTAssertEqual(CarbonModifiers.shift.rawValue, UInt32(shiftKey))
        XCTAssertEqual(CarbonModifiers.option.rawValue, UInt32(optionKey))
        XCTAssertEqual(CarbonModifiers.control.rawValue, UInt32(controlKey))
    }

    func testVirtualKeyCodesMatchCarbon() {
        XCTAssertEqual(VirtualKey.a, UInt32(kVK_ANSI_A))
        XCTAssertEqual(VirtualKey.r, UInt32(kVK_ANSI_R))
        XCTAssertEqual(VirtualKey.p, UInt32(kVK_ANSI_P))
        XCTAssertEqual(VirtualKey.one, UInt32(kVK_ANSI_1))
        XCTAssertEqual(VirtualKey.two, UInt32(kVK_ANSI_2))
        XCTAssertEqual(VirtualKey.three, UInt32(kVK_ANSI_3))
    }

    func testDefaultChords() {
        XCTAssertEqual(HotkeyAction.toggleRecording.defaultPreset.combo,
            KeyCombo(keyCode: UInt32(kVK_ANSI_R), modifiers: [.command, .shift], keyLabel: "R"))
        XCTAssertEqual(HotkeyAction.togglePause.defaultPreset.combo,
            KeyCombo(keyCode: UInt32(kVK_ANSI_P), modifiers: [.command, .shift], keyLabel: "P"))
        XCTAssertEqual(HotkeyAction.recordArea.defaultPreset.combo,
            KeyCombo(keyCode: UInt32(kVK_ANSI_A), modifiers: [.command, .shift], keyLabel: "A"))
    }

    func testEveryPresetButOffHasAUniqueChord() {
        let combos = HotkeyPreset.allCases.compactMap(\.combo)
        XCTAssertEqual(combos.count, HotkeyPreset.allCases.count - 1)
        XCTAssertEqual(Set(combos).count, combos.count, "two presets register the same chord")
        XCTAssertNil(HotkeyPreset.off.combo)
    }

    func testLabelsUseMenuGlyphOrder() {
        XCTAssertEqual(HotkeyPreset.commandShiftR.label, "⇧⌘R")
        XCTAssertEqual(HotkeyPreset.controlOptionA.label, "⌃⌥A")
        XCTAssertEqual(HotkeyPreset.controlOptionCommandP.label, "⌃⌥⌘P")
        XCTAssertEqual(HotkeyPreset.off.label, "Off")
        XCTAssertEqual(HotkeyPreset.commandShift1.combo?.keyEquivalent, "1")
        XCTAssertEqual(HotkeyPreset.commandShiftR.combo?.keyEquivalent, "r")
    }

    func testMatchingFindsThePresetForAChord() {
        let chord = KeyCombo(keyCode: UInt32(kVK_ANSI_2), modifiers: [.command, .shift], keyLabel: "2")
        XCTAssertEqual(HotkeyPreset.matching(chord), .commandShift2)
        let unknown = KeyCombo(keyCode: 99, modifiers: [.command], keyLabel: "?")
        XCTAssertNil(HotkeyPreset.matching(unknown))
    }

    func testActionIDsAreStableCarbonHotKeyIDs() {
        // Persisted nowhere, but registered with the OS: renumbering would
        // route a pressed chord to the wrong action.
        XCTAssertEqual(HotkeyAction.toggleRecording.rawValue, 1)
        XCTAssertEqual(HotkeyAction.togglePause.rawValue, 2)
        XCTAssertEqual(HotkeyAction.recordArea.rawValue, 3)
    }
}
