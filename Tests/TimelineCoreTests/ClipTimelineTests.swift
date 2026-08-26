import Foundation
import XCTest

@testable import TimelineCore

/// The cut model: output↔source mapping, split/ripple-delete operations,
/// and the invariants that keep preview==export true across cuts.
final class ClipTimelineTests: XCTestCase {

    private let second: Int64 = 1_000_000_000

    func testEmptyClipListIsIdentity() {
        let timeline = ClipTimeline(clips: [], sourceDurationNs: 10 * second)
        XCTAssertEqual(timeline.outputDurationNs, 10 * second)
        XCTAssertEqual(timeline.sourceTime(forOutput: 3 * second), 3 * second)
        XCTAssertEqual(timeline.outputTime(forSource: 7 * second), 7 * second)
    }

    func testMappingAcrossACut() {
        // Keep [0,4) and [6,10): output is 8 s.
        let clips = [
            Clip(sourceStartNs: 0, sourceEndNs: 4 * second),
            Clip(sourceStartNs: 6 * second, sourceEndNs: 10 * second),
        ]
        let timeline = ClipTimeline(clips: clips, sourceDurationNs: 10 * second)
        XCTAssertEqual(timeline.outputDurationNs, 8 * second)
        XCTAssertEqual(timeline.sourceTime(forOutput: 3 * second), 3 * second)
        // Output 5 s = 1 s into the second clip = source 7 s.
        XCTAssertEqual(timeline.sourceTime(forOutput: 5 * second), 7 * second)
        // Source 5 s was cut away.
        XCTAssertNil(timeline.outputTime(forSource: 5 * second))
        XCTAssertEqual(timeline.outputTimeSnapped(forSource: 5 * second), 4 * second)
        XCTAssertEqual(timeline.outputTime(forSource: 7 * second), 5 * second)
    }

    func testRoundTripFuzz() {
        var state: UInt64 = 99
        func rand(_ bound: Int64) -> Int64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Int64(state % UInt64(bound))
        }
        for _ in 0..<200 {
            // Random cut structure over 60 s.
            var boundaries = Set<Int64>()
            for _ in 0..<6 { boundaries.insert(rand(60 * second)) }
            let sorted = boundaries.sorted()
            var clips: [Clip] = []
            var keep = true
            var previous: Int64 = 0
            for boundary in sorted + [60 * second] {
                if keep, boundary > previous {
                    clips.append(Clip(sourceStartNs: previous, sourceEndNs: boundary))
                }
                keep.toggle()
                previous = boundary
            }
            let timeline = ClipTimeline(clips: clips, sourceDurationNs: 60 * second)
            guard timeline.outputDurationNs > 0 else { continue }
            for _ in 0..<50 {
                let output = rand(timeline.outputDurationNs)
                let source = timeline.sourceTime(forOutput: output)
                // Round trip is exact for kept times.
                XCTAssertEqual(timeline.outputTime(forSource: source), output)
            }
            // Monotonic mapping.
            var lastSource = Int64.min
            var probe: Int64 = 0
            while probe < timeline.outputDurationNs {
                let source = timeline.sourceTime(forOutput: probe)
                XCTAssertGreaterThan(source, lastSource)
                lastSource = source
                probe += 500_000_000
            }
        }
    }

    func testSplitAtPlayheadCreatesTwoClipsSharingTheBoundary() {
        let timeline = ClipTimeline(clips: [], sourceDurationNs: 10 * second)
        let split = timeline.splitting(atOutput: 4 * second)
        XCTAssertEqual(split.count, 2)
        XCTAssertEqual(split[0].sourceEndNs, 4 * second)
        XCTAssertEqual(split[1].sourceStartNs, 4 * second)
        // Output duration unchanged by a split.
        let after = ClipTimeline(clips: split, sourceDurationNs: 10 * second)
        XCTAssertEqual(after.outputDurationNs, 10 * second)
    }

    func testSplitTooCloseToEdgeIsRefused() {
        let timeline = ClipTimeline(clips: [], sourceDurationNs: 10 * second)
        XCTAssertEqual(timeline.splitting(atOutput: 20_000_000).count, 1)
        XCTAssertEqual(
            timeline.splitting(atOutput: 10 * second - 20_000_000).count, 1)
    }

    func testRippleDeleteClosesTheGap() {
        let timeline = ClipTimeline(clips: [], sourceDurationNs: 10 * second)
        let split = ClipTimeline(
            clips: timeline.splitting(atOutput: 4 * second),
            sourceDurationNs: 10 * second)
        let middleSplit = ClipTimeline(
            clips: split.splitting(atOutput: 6 * second),
            sourceDurationNs: 10 * second)
        XCTAssertEqual(middleSplit.clips.count, 3)
        let victim = middleSplit.clips[1]  // [4 s, 6 s)
        let remaining = ClipTimeline(
            clips: middleSplit.deleting(clipID: victim.id),
            sourceDurationNs: 10 * second)
        XCTAssertEqual(remaining.outputDurationNs, 8 * second)
        // Post-gap content ripples left: source 6 s now plays at output 4 s.
        XCTAssertEqual(remaining.sourceTime(forOutput: 4 * second), 6 * second)
    }

    func testDeletingTheOnlyClipIsRefused() {
        let timeline = ClipTimeline(clips: [], sourceDurationNs: 10 * second)
        let only = timeline.clips[0]
        XCTAssertEqual(timeline.deleting(clipID: only.id).count, 1)
    }

    func testHostileClipsAreNormalized() {
        // Overlapping, out-of-range, zero-length input all sanitized.
        let clips = [
            Clip(sourceStartNs: -5 * second, sourceEndNs: 3 * second),
            Clip(sourceStartNs: 3 * second, sourceEndNs: 3 * second),
            Clip(sourceStartNs: 8 * second, sourceEndNs: 99 * second),
        ]
        let timeline = ClipTimeline(clips: clips, sourceDurationNs: 10 * second)
        XCTAssertEqual(timeline.clips.count, 2)
        XCTAssertEqual(timeline.outputDurationNs, 5 * second)
        XCTAssertEqual(timeline.sourceTime(forOutput: 4 * second), 9 * second)
    }

    func testLegacyDocumentWithoutClipsDecodesUncut() throws {
        var document = EditDocument()
        document.schemaVersion = 1
        var json = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(document)) as! [String: Any]
        json.removeValue(forKey: "clips")
        let decoded = try JSONDecoder().decode(
            EditDocument.self,
            from: try JSONSerialization.data(withJSONObject: json))
        XCTAssertTrue(decoded.clips.isEmpty)
    }
}

extension ClipTimelineTests {
    // MARK: Speed

    func testSpeedShortensOutputAndMapsCorrectly() {
        let clips = [
            Clip(sourceStartNs: 0, sourceEndNs: 4_000_000_000),
            Clip(sourceStartNs: 4_000_000_000, sourceEndNs: 8_000_000_000, speed: 2),
            Clip(sourceStartNs: 8_000_000_000, sourceEndNs: 10_000_000_000),
        ]
        let timeline = ClipTimeline(clips: clips, sourceDurationNs: 10_000_000_000)
        // 4 + 4/2 + 2 = 8 s of output.
        XCTAssertEqual(timeline.outputDurationNs, 8_000_000_000)
        // Output 5 s = 1 s into the 2× clip = source 4 s + 2 s = 6 s.
        XCTAssertEqual(timeline.sourceTime(forOutput: 5_000_000_000), 6_000_000_000)
        // Source 6 s maps back to output 5 s.
        XCTAssertEqual(timeline.outputTime(forSource: 6_000_000_000), 5_000_000_000)
        // After the sped clip, mapping is offset but 1:1 again.
        XCTAssertEqual(timeline.sourceTime(forOutput: 7_000_000_000), 9_000_000_000)
    }

    func testSplitPreservesSpeed() {
        let clips = [Clip(sourceStartNs: 0, sourceEndNs: 8_000_000_000, speed: 4)]
        let timeline = ClipTimeline(clips: clips, sourceDurationNs: 8_000_000_000)
        // Output duration is 2 s; split at output 1 s (source 4 s).
        let split = timeline.splitting(atOutput: 1_000_000_000)
        XCTAssertEqual(split.count, 2)
        XCTAssertEqual(split[0].speed, 4)
        XCTAssertEqual(split[1].speed, 4)
        XCTAssertEqual(split[0].sourceEndNs, 4_000_000_000)
    }

    func testSettingSpeedClampsAndTargetsOneClip() {
        let timeline = ClipTimeline(clips: [], sourceDurationNs: 10_000_000_000)
        let base = timeline.clips[0]
        var updated = timeline.settingSpeed(100, clipID: base.id)
        XCTAssertEqual(updated[0].speed, 16)  // clamp
        updated = timeline.settingSpeed(0.01, clipID: base.id)
        XCTAssertEqual(updated[0].speed, 0.25)
        updated = timeline.settingSpeed(2, clipID: UUID())  // unknown id
        XCTAssertEqual(updated[0].speed, 1)
    }

    func testLegacyClipWithoutSpeedDecodesAtOneX() throws {
        let json = """
        {"id":"\(UUID().uuidString)","sourceStartNs":0,"sourceEndNs":1000}
        """
        let clip = try JSONDecoder().decode(Clip.self, from: Data(json.utf8))
        XCTAssertEqual(clip.speed, 1)
    }
}
