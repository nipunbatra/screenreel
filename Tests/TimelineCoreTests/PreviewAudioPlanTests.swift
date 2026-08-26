import XCTest

@testable import TimelineCore

/// Clip-aware preview audio planning: cuts skip, sped spans are silent,
/// kept spans land at their exact output offsets — export's audio policy.
final class PreviewAudioPlanTests: XCTestCase {

    func testUncutTimelineIsOnePassthroughEntry() {
        let timeline = ClipTimeline(clips: [], sourceDurationNs: 10_000_000_000)
        let plan = PreviewAudioPlan.entries(timeline: timeline, fromOutput: 0)
        XCTAssertEqual(plan, [
            AudioScheduleEntry(
                sourceStartNs: 0, lengthNs: 10_000_000_000, outputOffsetNs: 0)
        ])
    }

    func testStartMidTimelineSkipsIntoTheClip() {
        let timeline = ClipTimeline(clips: [], sourceDurationNs: 10_000_000_000)
        let plan = PreviewAudioPlan.entries(
            timeline: timeline, fromOutput: 4_000_000_000)
        XCTAssertEqual(plan, [
            AudioScheduleEntry(
                sourceStartNs: 4_000_000_000, lengthNs: 6_000_000_000,
                outputOffsetNs: 0)
        ])
    }

    func testCutSpanIsSkippedAndLaterClipOffsets() {
        // Keep [0,3) and [6,9): output is 6 s, second span starts at 3 s.
        let timeline = ClipTimeline(
            clips: [
                Clip(sourceStartNs: 0, sourceEndNs: 3_000_000_000),
                Clip(sourceStartNs: 6_000_000_000, sourceEndNs: 9_000_000_000),
            ],
            sourceDurationNs: 9_000_000_000)
        let plan = PreviewAudioPlan.entries(timeline: timeline, fromOutput: 0)
        XCTAssertEqual(plan, [
            AudioScheduleEntry(
                sourceStartNs: 0, lengthNs: 3_000_000_000, outputOffsetNs: 0),
            AudioScheduleEntry(
                sourceStartNs: 6_000_000_000, lengthNs: 3_000_000_000,
                outputOffsetNs: 3_000_000_000),
        ])
    }

    func testSpedClipIsSilentButLaterAudioStaysAligned() {
        // [0,4) at 1×, [4,12) at 4× (2 s output), [12,16) at 1×.
        let timeline = ClipTimeline(
            clips: [
                Clip(sourceStartNs: 0, sourceEndNs: 4_000_000_000),
                Clip(sourceStartNs: 4_000_000_000, sourceEndNs: 12_000_000_000, speed: 4),
                Clip(sourceStartNs: 12_000_000_000, sourceEndNs: 16_000_000_000),
            ],
            sourceDurationNs: 16_000_000_000)
        let plan = PreviewAudioPlan.entries(timeline: timeline, fromOutput: 0)
        // The sped span contributes NO entry; the final clip starts at
        // output 4 s + 2 s = 6 s.
        XCTAssertEqual(plan, [
            AudioScheduleEntry(
                sourceStartNs: 0, lengthNs: 4_000_000_000, outputOffsetNs: 0),
            AudioScheduleEntry(
                sourceStartNs: 12_000_000_000, lengthNs: 4_000_000_000,
                outputOffsetNs: 6_000_000_000),
        ])
    }

    func testStartInsideSpedSpanSchedulesOnlyTheTail() {
        let timeline = ClipTimeline(
            clips: [
                Clip(sourceStartNs: 0, sourceEndNs: 4_000_000_000),
                Clip(sourceStartNs: 4_000_000_000, sourceEndNs: 12_000_000_000, speed: 4),
                Clip(sourceStartNs: 12_000_000_000, sourceEndNs: 16_000_000_000),
            ],
            sourceDurationNs: 16_000_000_000)
        // Output 5 s is inside the sped span (4–6 s): only the tail clip
        // plays, 1 s from now.
        let plan = PreviewAudioPlan.entries(
            timeline: timeline, fromOutput: 5_000_000_000)
        XCTAssertEqual(plan, [
            AudioScheduleEntry(
                sourceStartNs: 12_000_000_000, lengthNs: 4_000_000_000,
                outputOffsetNs: 1_000_000_000)
        ])
    }

    /// The trim-remap identity used by the editor: an output trim converted
    /// through source time survives a ripple delete pointing at the same
    /// content, not the same clock time.
    func testTrimRemapThroughRippleDeleteKeepsSourceAnchor() {
        let before = ClipTimeline(clips: [], sourceDurationNs: 60_000_000_000)
        let trimEndOutput: Int64 = 40_000_000_000  // "end at source 40 s"
        let trimEndSource = before.sourceTime(forOutput: trimEndOutput)

        // Ripple-delete [10 s, 20 s): output shrinks by 10 s.
        let after = ClipTimeline(
            clips: [
                Clip(sourceStartNs: 0, sourceEndNs: 10_000_000_000),
                Clip(sourceStartNs: 20_000_000_000, sourceEndNs: 60_000_000_000),
            ],
            sourceDurationNs: 60_000_000_000)
        let remapped = after.outputTimeSnapped(forSource: trimEndSource)
        // Same content boundary: source 40 s now sits at output 30 s.
        XCTAssertEqual(Double(remapped), 30e9, accuracy: 2e6)
    }
}
