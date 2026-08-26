import Foundation
import XCTest

@testable import TimelineCore

/// The "fast-forward the typing" brain: idle+quiet spans found, active or
/// loud spans spared, and application produces sped clips around each span.
final class DeadStretchDetectorTests: XCTestCase {

    private let second: Int64 = 1_000_000_000

    private func inputs(
        duration: Int64,
        clicks: [Int64] = [],
        cursorIdle: Bool = true,
        loudRanges: [(Double, Double)] = []
    ) -> DeadStretchDetector.Inputs {
        // Cursor: parked, or sweeping constantly.
        var cursor: [(timeNs: Int64, x: Double, y: Double)] = []
        var t: Int64 = 0
        var x = 100.0
        while t < duration {
            cursor.append((t, x, 200))
            if !cursorIdle { x += 30 }
            t += 250_000_000
        }
        // Audio buckets: quiet except the given fractional ranges.
        let buckets = 200
        var levels = [Float](repeating: 0.03, count: buckets)
        for range in loudRanges {
            for index in Int(range.0 * Double(buckets))..<Int(range.1 * Double(buckets)) {
                levels[index] = 0.6
            }
        }
        return .init(
            clickTimesNs: clicks, cursorSamples: cursor,
            audioLevels: levels, sourceDurationNs: duration)
    }

    func testFullyIdleQuietRecordingIsOneBigSpan() {
        let spans = DeadStretchDetector.detect(inputs(duration: 60 * second))
        XCTAssertEqual(spans.count, 1)
        XCTAssertGreaterThan(spans[0].endNs - spans[0].startNs, 50 * second)
    }

    func testTalkingSpansAreSpared() {
        // Loud audio through the middle half.
        let spans = DeadStretchDetector.detect(
            inputs(duration: 80 * second, loudRanges: [(0.25, 0.75)]))
        XCTAssertEqual(spans.count, 2, "quiet head and tail only")
        for span in spans {
            XCTAssertFalse(
                span.startNs > 20 * second && span.endNs < 60 * second,
                "detected span overlaps the talking range")
        }
    }

    func testActiveCursorSpares() {
        let spans = DeadStretchDetector.detect(
            inputs(duration: 60 * second, cursorIdle: false))
        XCTAssertTrue(spans.isEmpty)
    }

    func testClicksBreakSpans() {
        let spans = DeadStretchDetector.detect(
            inputs(duration: 40 * second, clicks: [20 * second]))
        // The click splits the idle block; both halves still qualify.
        XCTAssertEqual(spans.count, 2)
    }

    func testShortIdleGapsAreIgnored() {
        // 6 s of idle between talking — below the 8 s minimum.
        let spans = DeadStretchDetector.detect(
            inputs(
                duration: 30 * second,
                loudRanges: [(0.0, 0.4), (0.6, 1.0)]))
        XCTAssertTrue(spans.isEmpty)
    }

    func testApplyingCreatesSpedClipsAroundSpans() {
        let timeline = ClipTimeline(clips: [], sourceDurationNs: 60 * second)
        let spans = [(startNs: 10 * second, endNs: 30 * second)]
        let clips = DeadStretchDetector.applying(spans: spans, to: timeline, speed: 4)
        let applied = ClipTimeline(clips: clips, sourceDurationNs: 60 * second)
        XCTAssertEqual(applied.clips.count, 3)
        XCTAssertEqual(applied.clips[1].speed, 4)
        XCTAssertEqual(applied.clips[0].speed, 1)
        XCTAssertEqual(applied.clips[2].speed, 1)
        // Output: 10 + 20/4 + 30 = 45 s.
        XCTAssertEqual(applied.outputDurationNs, 45 * second)
    }
}

extension DeadStretchDetectorTests {
    /// A dead span holding SEVERAL clips (user split inside it earlier)
    /// must speed every one of them — the original loop discarded all but
    /// the last assignment.
    func testSpanCoveringMultipleClipsSpeedsAllOfThem() {
        let timeline = ClipTimeline(
            clips: [
                Clip(sourceStartNs: 0, sourceEndNs: 10_000_000_000),
                Clip(sourceStartNs: 10_000_000_000, sourceEndNs: 15_000_000_000),
                Clip(sourceStartNs: 15_000_000_000, sourceEndNs: 30_000_000_000),
            ],
            sourceDurationNs: 30_000_000_000)
        // Dead span [8 s, 20 s): fully contains the middle clip and splits
        // into the outer two.
        let spans: [(startNs: Int64, endNs: Int64)] = [
            (startNs: 8_000_000_000, endNs: 20_000_000_000)
        ]
        let clips = DeadStretchDetector.applying(
            spans: spans, to: timeline, speed: 4)

        let result = ClipTimeline(clips: clips, sourceDurationNs: 30_000_000_000)
        // Every clip fully inside the span is sped; everything else is 1×.
        for clip in result.clips {
            let insideSpan = clip.sourceStartNs >= 8_000_000_000 - 1_000_000
                && clip.sourceEndNs <= 20_000_000_000 + 1_000_000
            if insideSpan {
                XCTAssertEqual(clip.speed, 4, accuracy: 0.001,
                    "clip [\(clip.sourceStartNs), \(clip.sourceEndNs)) must be sped")
            } else {
                XCTAssertEqual(clip.speed, 1, accuracy: 0.001)
            }
        }
        // The span survives as ≥2 sped clips (10 s and 15 s boundaries).
        let spedCount = result.clips.filter { $0.speed > 1.5 }.count
        XCTAssertGreaterThanOrEqual(spedCount, 2,
            "both pre-existing clips inside the span must be sped, got \(result.clips.map { ($0.sourceStartNs, $0.speed) })")
    }
}
