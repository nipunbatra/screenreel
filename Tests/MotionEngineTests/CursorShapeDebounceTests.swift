import Foundation
import ProjectModel
import XCTest

@testable import MotionEngine

/// Cursor-shape debounce: beam↔pointer flicker during fast
/// text selection must not strobe the rendered cursor. Sub-100 ms shape
/// blips coalesce in the DERIVED timeline; raw events are untouched.
final class CursorShapeDebounceTests: XCTestCase {

    private func shapeEvent(_ timeNs: Int64, _ id: String, seq: UInt64) -> EventRecord {
        EventRecord(
            sequence: seq, timeNs: timeNs, type: .cursorShapeChanged,
            displayID: 1, xPx: 10, yPx: 10, cursorID: id)
    }

    func testSubThresholdFlickerIsCoalesced() {
        // pointer …(50 ms beam blip)… pointer …(long beam)…
        let events = [
            shapeEvent(0, "arrow", seq: 1),
            shapeEvent(1_000_000_000, "ibeam", seq: 2),      // 50 ms blip
            shapeEvent(1_050_000_000, "arrow", seq: 3),
            shapeEvent(2_000_000_000, "ibeam", seq: 4),      // real change
        ]
        let timeline = MotionTimeline(events: events)
        XCTAssertEqual(timeline.cursorID(at: 1_020_000_000), "arrow",
            "50 ms blip must not surface")
        XCTAssertEqual(timeline.cursorID(at: 2_500_000_000), "ibeam",
            "sustained change survives")
    }

    func testLongSegmentsAreNeverCoalesced() {
        let events = [
            shapeEvent(0, "arrow", seq: 1),
            shapeEvent(1_000_000_000, "ibeam", seq: 2),      // 900 ms — keep
            shapeEvent(1_900_000_000, "arrow", seq: 3),
        ]
        let timeline = MotionTimeline(events: events)
        XCTAssertEqual(timeline.cursorID(at: 1_500_000_000), "ibeam")
        XCTAssertEqual(timeline.cursorID(at: 2_500_000_000), "arrow")
    }

    func testFinalShapeAlwaysSurvivesEvenIfRecent() {
        let events = [
            shapeEvent(0, "arrow", seq: 1),
            shapeEvent(5_000_000_000, "ibeam", seq: 2),  // final, 0 lifetime
        ]
        let timeline = MotionTimeline(events: events)
        XCTAssertEqual(timeline.cursorID(at: 6_000_000_000), "ibeam",
            "the last shape is the current shape, regardless of age")
    }

    func testRapidFlickerBurstCollapsesToSurroundingShape() {
        var events: [EventRecord] = [shapeEvent(0, "arrow", seq: 0)]
        // 10 alternations, 30 ms apart, then back to arrow for good.
        for index in 0..<10 {
            events.append(shapeEvent(
                1_000_000_000 + Int64(index) * 30_000_000,
                index % 2 == 0 ? "ibeam" : "arrow",
                seq: UInt64(index + 1)))
        }
        events.append(shapeEvent(3_000_000_000, "arrow", seq: 99))
        let timeline = MotionTimeline(events: events)
        for probe in stride(from: Int64(1_000_000_000), to: 1_300_000_000, by: 40_000_000) {
            XCTAssertEqual(timeline.cursorID(at: probe), "arrow",
                "burst at \(probe) must read as the surrounding arrow")
        }
    }
}
