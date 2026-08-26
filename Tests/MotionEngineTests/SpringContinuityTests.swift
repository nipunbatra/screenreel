import Foundation
import ProjectModel
import TimelineCore
import XCTest

@testable import MotionEngine

/// Two zoom-spring strengtheners: velocity is
/// continuous across zoom-segment boundaries (no visible "kick"), and
/// evaluating an hour-long timeline stays cheap.
final class SpringContinuityTests: XCTestCase {

    func testVelocityContinuousAcrossZoomBoundaries() {
        // Two adjacent zooms with different targets: sample scale around
        // the boundary; the discrete velocity must not jump by more than
        // the spring's own acceleration allows (no teleporting state).
        let zooms = [
            ZoomSegment(startNs: 1_000_000_000, endNs: 4_000_000_000, scale: 2.0),
            ZoomSegment(startNs: 4_000_000_000, endNs: 7_000_000_000, scale: 3.0),
        ]
        let engine = CameraEngine(zooms: zooms, durationNs: 10_000_000_000)
        let stepNs: Int64 = 8_000_000
        var previousScale: Double?
        var previousVelocity: Double?
        var maxVelocityJump = 0.0
        var timeNs: Int64 = 3_800_000_000
        while timeNs <= 4_200_000_000 {
            defer { timeNs += stepNs }
            let scale = engine.state(at: timeNs).scale
            if let last = previousScale {
                let velocity = (scale - last) / (Double(stepNs) / 1e9)
                if let lastVelocity = previousVelocity {
                    maxVelocityJump = max(
                        maxVelocityJump, abs(velocity - lastVelocity))
                }
                previousVelocity = velocity
            }
            previousScale = scale
        }
        // A hard state reset at the boundary shows up as a velocity step of
        // tens of units/s; continuous spring evolution stays far below.
        XCTAssertLessThan(maxVelocityJump, 5.0,
            "velocity discontinuity at zoom boundary: \(maxVelocityJump)/s")
    }

    func testHourLongTimelineEvaluatesCheaply() {
        // 240 zooms over an hour; random seeks must stay fast (checkpoint
        // design), bounding editor scrubbing cost for real lectures.
        var zooms: [ZoomSegment] = []
        for index in 0..<240 {
            let start = Int64(index) * 15_000_000_000
            zooms.append(ZoomSegment(
                startNs: start, endNs: start + 5_000_000_000,
                scale: 1.5 + Double(index % 3)))
        }
        let hourNs: Int64 = 3_600_000_000_000
        let built = Date()
        let engine = CameraEngine(zooms: zooms, durationNs: hourNs)
        let buildSeconds = Date().timeIntervalSince(built)

        var rng: UInt64 = 7
        let seekStart = Date()
        for _ in 0..<200 {
            rng = rng &* 6364136223846793005 &+ 1442695040888963407
            _ = engine.state(at: Int64(rng % UInt64(hourNs)))
        }
        let seekSeconds = Date().timeIntervalSince(seekStart)
        XCTAssertLessThan(buildSeconds, 2.0, "hour-timeline build too slow")
        XCTAssertLessThan(seekSeconds, 2.0, "200 random hour-timeline seeks too slow")
    }
}

extension SpringContinuityTests {
    /// The cursor engine faces DENSER data than zooms: an hour of 60 Hz
    /// moves. Random seeks must stay usable.
    func testHourOfCursorMovesEvaluatesCheaply() {
        var events: [EventRecord] = []
        var sequence: UInt64 = 0
        // 60 Hz moves for an hour = 216k events (realistic lecture).
        var timeNs: Int64 = 0
        let hourNs: Int64 = 3_600_000_000_000
        while timeNs < hourNs {
            sequence += 1
            events.append(EventRecord(
                sequence: sequence, timeNs: timeNs, type: .cursorMove,
                displayID: 1,
                xPx: Double(500 + (timeNs / 16_666_666) % 800),
                yPx: Double(400 + (timeNs / 33_333_333) % 500)))
            timeNs += 16_666_666
        }
        let timeline = MotionTimeline(events: events)
        let engine = CursorEngine(
            timeline: timeline, settings: CursorSettings(), durationNs: hourNs)
        var rng: UInt64 = 11
        let start = Date()
        for _ in 0..<50 {
            rng = rng &* 6364136223846793005 &+ 1442695040888963407
            _ = engine.state(at: Int64(rng % UInt64(hourNs)))
        }
        let seconds = Date().timeIntervalSince(start)
        XCTAssertLessThan(seconds, 5.0, "50 random hour-cursor seeks took \(seconds)s")
    }
}
