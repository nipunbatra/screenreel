import Foundation
import XCTest

@testable import TimelineCore

/// Timeline helpers that back the editor UI: ruler tick spacing and the
/// zoom Duplicate action.
final class RulerAndDuplicateTests: XCTestCase {

    // MARK: Ruler

    func testShortRecordingUsesOneSecondTicks() {
        XCTAssertEqual(TimelineRuler.stepSeconds(forDuration: 10), 1)
    }

    func testMediumRecordingsClimbTheLadder() {
        XCTAssertEqual(TimelineRuler.stepSeconds(forDuration: 60), 5)
        XCTAssertEqual(TimelineRuler.stepSeconds(forDuration: 300), 30)
        XCTAssertEqual(TimelineRuler.stepSeconds(forDuration: 3600), 300)
    }

    func testLabelCountStaysReadableAcrossDurations() {
        for seconds in [5.0, 47, 90, 600, 1800, 5400, 7200] {
            let step = TimelineRuler.stepSeconds(forDuration: seconds)
            let labels = seconds / step
            XCTAssertLessThanOrEqual(labels, 12.5, "duration \(seconds)s → \(labels) labels")
            XCTAssertGreaterThanOrEqual(labels, 1, "duration \(seconds)s has no ticks")
        }
    }

    func testAbsurdDurationStillCapsAtLadderTop() {
        XCTAssertEqual(TimelineRuler.stepSeconds(forDuration: 100_000), 900)
    }

    func testLabelStepNeverLetsLabelsCollide() {
        // At any width/duration combination, adjacent labels get at least
        // the minimum spacing (the overlapping-ruler bug).
        for seconds in [10.0, 45, 90, 600, 3600] {
            for width in [200.0, 400, 800, 1600] {
                let step = TimelineRuler.labelStep(forDuration: seconds, width: width)
                let spacing = width * step / seconds
                XCTAssertGreaterThanOrEqual(
                    spacing, 56,
                    "labels \(spacing)pt apart at \(seconds)s × \(width)pt")
            }
        }
    }

    func testLabelStepMatchesBaseStepWhenRoomIsAmple() {
        XCTAssertEqual(
            TimelineRuler.labelStep(forDuration: 60, width: 2000),
            TimelineRuler.stepSeconds(forDuration: 60))
    }

    func testLabelStepHandlesDegenerateInputs() {
        // Zero width/duration must not loop forever or crash.
        XCTAssertGreaterThan(TimelineRuler.labelStep(forDuration: 0, width: 500), 0)
        XCTAssertGreaterThan(TimelineRuler.labelStep(forDuration: 60, width: 0), 0)
        // A tiny width caps the doubling at the duration itself.
        XCTAssertLessThanOrEqual(
            TimelineRuler.labelStep(forDuration: 30, width: 40), 60)
    }

    // MARK: Duplicate

    func testDuplicateLandsRightAfterOriginal() {
        let zoom = ZoomSegment(startNs: 1_000_000_000, endNs: 3_000_000_000, scale: 2.5)
        let copy = zoom.duplicatedAfter(durationNs: 60_000_000_000)
        XCTAssertEqual(copy.startNs, zoom.endNs)
        XCTAssertEqual(copy.endNs - copy.startNs, zoom.endNs - zoom.startNs)
        XCTAssertEqual(copy.scale, zoom.scale)
        XCTAssertNotEqual(copy.id, zoom.id)
        XCTAssertEqual(copy.origin, "manual")
    }

    func testDuplicateNearEndClampsInsideRecording() {
        let zoom = ZoomSegment(startNs: 8_000_000_000, endNs: 9_500_000_000)
        let copy = zoom.duplicatedAfter(durationNs: 10_000_000_000)
        XCTAssertLessThanOrEqual(copy.endNs, 10_000_000_000)
        XCTAssertGreaterThanOrEqual(copy.startNs, 0)
        XCTAssertGreaterThan(copy.endNs, copy.startNs)
        // And never an exact overlap with the original (invisible no-op).
        XCTAssertFalse(copy.startNs == zoom.startNs && copy.endNs == zoom.endNs)
    }

    func testDuplicateWithNoTailRoomPlacesBeforeOriginal() {
        // [7 s, 10 s] of a 10 s recording: nothing fits after; the copy
        // must land before, not exactly on top of the original.
        let zoom = ZoomSegment(startNs: 7_000_000_000, endNs: 10_000_000_000)
        let copy = zoom.duplicatedAfter(durationNs: 10_000_000_000)
        XCTAssertLessThanOrEqual(copy.endNs, zoom.startNs)
        XCTAssertGreaterThanOrEqual(copy.startNs, 0)
        XCTAssertGreaterThanOrEqual(
            copy.endNs - copy.startNs, ZoomSegment.minLengthNs)
    }

    func testDuplicateOfGeneratedZoomBecomesManual() {
        let zoom = ZoomSegment(
            startNs: 0, endNs: 2_000_000_000, origin: "generated")
        let copy = zoom.duplicatedAfter(durationNs: 30_000_000_000)
        // Regenerating auto-zooms must never wipe a user's duplicate.
        XCTAssertEqual(copy.origin, "manual")
    }

    func testDuplicateLongerThanRemainingTailShrinksToFit() {
        // Segment longer than the remaining tail: the copy starts right
        // after the original and shrinks to the available room.
        let zoom = ZoomSegment(startNs: 4_000_000_000, endNs: 9_000_000_000)
        let copy = zoom.duplicatedAfter(durationNs: 10_000_000_000)
        XCTAssertEqual(copy.startNs, 9_000_000_000)
        XCTAssertEqual(copy.endNs, 10_000_000_000)
    }
}
