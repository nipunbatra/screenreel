import Foundation
import TimelineCore
import XCTest

@testable import Captions

/// The pure caption layer: shaping, timestamp formats, serialization, and
/// remapping through cuts/speeds. (Recognition itself needs user
/// authorization and on-device models — covered manually.)
final class CaptionWriterTests: XCTestCase {

    private let second: Int64 = 1_000_000_000

    // MARK: Timestamps

    func testTimestampFormats() {
        // 1 h 2 m 3.456 s
        let ns: Int64 = 3_723_456_000_000
        XCTAssertEqual(CaptionWriter.timestamp(ns, format: .srt), "01:02:03,456")
        XCTAssertEqual(CaptionWriter.timestamp(ns, format: .vtt), "01:02:03.456")
        XCTAssertEqual(CaptionWriter.timestamp(0, format: .srt), "00:00:00,000")
        XCTAssertEqual(CaptionWriter.timestamp(-5, format: .vtt), "00:00:00.000")
    }

    // MARK: Shaping

    func testFragmentsMergeIntoReadableCues() {
        let raw = [
            CaptionCue(startNs: 0, endNs: second, text: "today"),
            CaptionCue(startNs: second, endNs: 2 * second, text: "we study"),
            CaptionCue(startNs: 2 * second, endNs: 3 * second, text: "gradient descent"),
        ]
        let cues = CaptionWriter.shaped(raw)
        XCTAssertEqual(cues.count, 1)
        XCTAssertEqual(cues[0].text, "today we study gradient descent")
    }

    func testLongGapSplitsCues() {
        let raw = [
            CaptionCue(startNs: 0, endNs: second, text: "first thought"),
            CaptionCue(startNs: 5 * second, endNs: 6 * second, text: "second thought"),
        ]
        let cues = CaptionWriter.shaped(raw)
        XCTAssertEqual(cues.count, 2)
    }

    func testLineLengthCapSplits() {
        let raw = (0..<12).map { index in
            CaptionCue(
                startNs: Int64(index) * 500_000_000,
                endNs: Int64(index + 1) * 500_000_000,
                text: "supercalifragilistic")
        }
        let cues = CaptionWriter.shaped(raw, maxCharacters: 60)
        XCTAssertGreaterThan(cues.count, 1)
        XCTAssertTrue(cues.allSatisfy { $0.text.count <= 60 })
    }

    func testCuesNeverOverlapAfterMinDurationClamp() {
        let raw = [
            CaptionCue(startNs: 0, endNs: 100_000_000, text: "hi"),
            CaptionCue(startNs: 2 * second, endNs: 2 * second + 100_000_000, text: "there"),
        ]
        let cues = CaptionWriter.shaped(raw)
        for (a, b) in zip(cues, cues.dropFirst()) {
            XCTAssertLessThanOrEqual(a.endNs, b.startNs)
        }
    }

    func testEmptyAndWhitespaceFragmentsDrop() {
        let cues = CaptionWriter.shaped([
            CaptionCue(startNs: 0, endNs: second, text: "  "),
            CaptionCue(startNs: second, endNs: 2 * second, text: ""),
        ])
        XCTAssertTrue(cues.isEmpty)
    }

    // MARK: Serialization

    func testSRTSerialization() {
        let text = CaptionWriter.serialize([
            CaptionCue(startNs: 0, endNs: 2 * second, text: "hello"),
            CaptionCue(startNs: 3 * second, endNs: 5 * second, text: "world"),
        ], format: .srt)
        XCTAssertTrue(text.hasPrefix("1\n00:00:00,000 --> 00:00:02,000\nhello\n\n"))
        XCTAssertTrue(text.contains("2\n00:00:03,000 --> 00:00:05,000\nworld\n\n"))
    }

    func testVTTSerialization() {
        let text = CaptionWriter.serialize([
            CaptionCue(startNs: 0, endNs: second, text: "hej"),
        ], format: .vtt)
        XCTAssertTrue(text.hasPrefix("WEBVTT\n\n"))
        XCTAssertTrue(text.contains("00:00:00.000 --> 00:00:01.000\nhej"))
    }

    // MARK: Remap through cuts/speeds

    func testCueInCutAwaySpanDrops() {
        let timeline = ClipTimeline(
            clips: [
                Clip(sourceStartNs: 0, sourceEndNs: 3 * second),
                Clip(sourceStartNs: 6 * second, sourceEndNs: 9 * second),
            ],
            sourceDurationNs: 9 * second)
        let cues = CaptionWriter.remapped([
            CaptionCue(startNs: second, endNs: 2 * second, text: "kept"),
            CaptionCue(startNs: 4 * second, endNs: 5 * second, text: "cut away"),
            CaptionCue(startNs: 7 * second, endNs: 8 * second, text: "ripples left"),
        ], through: timeline)
        XCTAssertEqual(cues.map(\.text), ["kept", "ripples left"])
        // Source 7 s → output 4 s after the ripple.
        XCTAssertEqual(cues[1].startNs, 4 * second)
    }

    func testCueOverSpedSpanCompresses() {
        let timeline = ClipTimeline(
            clips: [Clip(sourceStartNs: 0, sourceEndNs: 8 * second, speed: 2)],
            sourceDurationNs: 8 * second)
        let cues = CaptionWriter.remapped(
            [CaptionCue(startNs: 2 * second, endNs: 6 * second, text: "fast")],
            through: timeline)
        XCTAssertEqual(cues.count, 1)
        XCTAssertEqual(cues[0].startNs, 1 * second)
        XCTAssertEqual(Double(cues[0].endNs), 3e9, accuracy: 2e6)
    }
}

extension CaptionWriterTests {
    // MARK: clipped(toRange:) — the export-trim contract

    func testClippedRebasesToTrimStart() {
        let cues = [
            CaptionCue(startNs: 5_000_000_000, endNs: 7_000_000_000, text: "kept"),
        ]
        let out = CaptionWriter.clipped(
            cues, toRange: (startNs: 3_000_000_000, endNs: 10_000_000_000))
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].startNs, 2_000_000_000)
        XCTAssertEqual(out[0].endNs, 4_000_000_000)
        XCTAssertEqual(out[0].text, "kept")
    }

    func testClippedDropsCuesOutsideRange() {
        let cues = [
            CaptionCue(startNs: 0, endNs: 2_000_000_000, text: "before"),
            CaptionCue(startNs: 4_000_000_000, endNs: 5_000_000_000, text: "inside"),
            CaptionCue(startNs: 11_000_000_000, endNs: 12_000_000_000, text: "after"),
        ]
        let out = CaptionWriter.clipped(
            cues, toRange: (startNs: 3_000_000_000, endNs: 10_000_000_000))
        XCTAssertEqual(out.map(\.text), ["inside"])
    }

    func testClippedShortensStraddlingCues() {
        let cues = [
            CaptionCue(startNs: 2_000_000_000, endNs: 4_000_000_000, text: "head"),
            CaptionCue(startNs: 9_000_000_000, endNs: 12_000_000_000, text: "tail"),
        ]
        let out = CaptionWriter.clipped(
            cues, toRange: (startNs: 3_000_000_000, endNs: 10_000_000_000))
        XCTAssertEqual(out.count, 2)
        // Head cue keeps only its in-range second, starting at 0.
        XCTAssertEqual(out[0].startNs, 0)
        XCTAssertEqual(out[0].endNs, 1_000_000_000)
        // Tail cue is cut at the range end.
        XCTAssertEqual(out[1].startNs, 6_000_000_000)
        XCTAssertEqual(out[1].endNs, 7_000_000_000)
    }

    func testClippedIdentityWhenRangeCoversAll() {
        let cues = [
            CaptionCue(startNs: 1_000_000_000, endNs: 2_000_000_000, text: "a"),
            CaptionCue(startNs: 3_000_000_000, endNs: 4_000_000_000, text: "b"),
        ]
        let out = CaptionWriter.clipped(cues, toRange: (startNs: 0, endNs: 10_000_000_000))
        XCTAssertEqual(out, cues)
    }

    func testClippedEmptyRangeDropsEverything() {
        let cues = [CaptionCue(startNs: 0, endNs: 1_000_000_000, text: "x")]
        XCTAssertTrue(
            CaptionWriter.clipped(
                cues, toRange: (startNs: 5_000_000_000, endNs: 5_000_000_000)
            ).isEmpty)
    }
}

extension CaptionWriterTests {
    // MARK: remapped() partial-overlap survival

    func testCueStartingInsideCutKeepsItsKeptRemainder() {
        // Cut [0,5); keep [5,10). Cue [3 s, 8 s) → kept part is [5,8) →
        // output [0, 3 s). The endpoint-probe version collapsed this to 1 ns.
        let timeline = ClipTimeline(
            clips: [Clip(sourceStartNs: 5_000_000_000, sourceEndNs: 10_000_000_000)],
            sourceDurationNs: 10_000_000_000)
        let out = CaptionWriter.remapped(
            [CaptionCue(startNs: 3_000_000_000, endNs: 8_000_000_000, text: "talk")],
            through: timeline)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].startNs, 0)
        XCTAssertEqual(Double(out[0].endNs), 3e9, accuracy: 2e6)
    }

    func testCueWithBothEndpointsCutButMiddleKeptSurvives() {
        // Keep only [10 s, 20 s). Cue [5 s, 25 s) overlaps the kept middle
        // → output [0, 10 s). The endpoint-probe version dropped it.
        let timeline = ClipTimeline(
            clips: [Clip(sourceStartNs: 10_000_000_000, sourceEndNs: 20_000_000_000)],
            sourceDurationNs: 30_000_000_000)
        let out = CaptionWriter.remapped(
            [CaptionCue(startNs: 5_000_000_000, endNs: 25_000_000_000, text: "long")],
            through: timeline)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].startNs, 0)
        XCTAssertEqual(Double(out[0].endNs), 10e9, accuracy: 2e6)
    }

    func testFullyCutCueStillDrops() {
        let timeline = ClipTimeline(
            clips: [Clip(sourceStartNs: 10_000_000_000, sourceEndNs: 20_000_000_000)],
            sourceDurationNs: 30_000_000_000)
        XCTAssertTrue(CaptionWriter.remapped(
            [CaptionCue(startNs: 2_000_000_000, endNs: 8_000_000_000, text: "gone")],
            through: timeline
        ).isEmpty)
    }

    func testCueOverSpedSpanCompressesWithIt() {
        // Whole timeline at 2×: cue [2 s, 6 s) → output [1 s, 3 s).
        let timeline = ClipTimeline(
            clips: [Clip(sourceStartNs: 0, sourceEndNs: 10_000_000_000, speed: 2)],
            sourceDurationNs: 10_000_000_000)
        let out = CaptionWriter.remapped(
            [CaptionCue(startNs: 2_000_000_000, endNs: 6_000_000_000, text: "fast")],
            through: timeline)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(Double(out[0].startNs), 1e9, accuracy: 2e6)
        XCTAssertEqual(Double(out[0].endNs), 3e9, accuracy: 2e6)
    }
}
