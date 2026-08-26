import ProjectModel
import XCTest

@testable import MotionEngine

/// Shortcut-chip evaluation: labels, the shortcuts-only privacy filter,
/// and the lifecycle window.
final class KeystrokeChipsTests: XCTestCase {

    private func press(
        _ tNs: Int64, code: Int, _ modifiers: [EventModifier] = []
    ) -> MotionTimeline.KeyPress {
        MotionTimeline.KeyPress(timeNs: tNs, keyCode: code, modifiers: modifiers)
    }

    func testLabelUsesHIGModifierOrder() {
        // ⌃⌥⇧⌘ ordering regardless of the array order recorded.
        let label = KeystrokeChips.label(for: press(
            0, code: 35, [.command, .shift, .option, .control]))
        XCTAssertEqual(label, "⌃⌥⇧⌘P")
        XCTAssertEqual(
            KeystrokeChips.label(for: press(0, code: 8, [.command])), "⌘C")
        XCTAssertEqual(
            KeystrokeChips.label(for: press(0, code: 49, [.command])), "⌘Space")
    }

    func testKeycodeTableSpotChecks() {
        XCTAssertEqual(KeystrokeChips.keyLabel(36), "↩")
        XCTAssertEqual(KeystrokeChips.keyLabel(53), "⎋")
        XCTAssertEqual(KeystrokeChips.keyLabel(123), "←")
        XCTAssertEqual(KeystrokeChips.keyLabel(122), "F1")
        XCTAssertEqual(KeystrokeChips.keyLabel(999), "key999")
    }

    /// The privacy filter: plain typing NEVER renders.
    func testOnlyShortcutsPassTheFilter() {
        XCTAssertFalse(KeystrokeChips.isShortcut(press(0, code: 0)))  // "a"
        XCTAssertFalse(
            KeystrokeChips.isShortcut(press(0, code: 0, [.shift])))  // "A"
        XCTAssertFalse(
            KeystrokeChips.isShortcut(press(0, code: 49)))  // space
        XCTAssertTrue(
            KeystrokeChips.isShortcut(press(0, code: 8, [.command])))  // ⌘C
        XCTAssertTrue(
            KeystrokeChips.isShortcut(press(0, code: 96)))  // F5
        XCTAssertTrue(KeystrokeChips.isShortcut(press(0, code: 53)))  // esc
        // fn alone must NOT qualify: macOS sets the fn flag on plain
        // arrow/Home/End presses.
        XCTAssertFalse(
            KeystrokeChips.isShortcut(press(0, code: 2, [.fn])))
        XCTAssertFalse(
            KeystrokeChips.isShortcut(press(0, code: 123, [.fn])))  // bare ←
    }

    func testChipLifecycleAndCap() {
        let presses = [
            press(1_000_000_000, code: 8, [.command]),
            press(1_100_000_000, code: 9, [.command]),
            press(1_200_000_000, code: 35, [.command, .shift]),
            press(1_300_000_000, code: 0, []),  // typing: filtered out
            press(1_350_000_000, code: 45, [.command]),
        ]
        let active = KeystrokeChips.chips(presses: presses, atSource: 1_400_000_000)
        // Four shortcuts alive, capped to the newest three.
        XCTAssertEqual(active.map(\.label), ["⌘V", "⇧⌘P", "⌘N"])
        XCTAssertGreaterThan(active[0].progress, active[1].progress)

        // All expired.
        XCTAssertTrue(
            KeystrokeChips.chips(presses: presses, atSource: 3_000_000_000).isEmpty)
    }

    func testTimelineCollectsKeyDownsOnly() {
        let events = [
            EventRecord(
                sequence: 1, timeNs: 10, type: .keyDown,
                modifiers: [.command], keyCode: 8),
            EventRecord(sequence: 2, timeNs: 20, type: .flagsChanged, keyCode: 55),
            EventRecord(
                sequence: 3, timeNs: 30, type: .keyDown, modifiers: [], keyCode: 0),
        ]
        let timeline = MotionTimeline(events: events)
        XCTAssertEqual(timeline.keyPresses.count, 2)
        XCTAssertEqual(timeline.keyPresses[0].keyCode, 8)
        XCTAssertEqual(timeline.keyPresses[0].modifiers, [.command])
    }
}
