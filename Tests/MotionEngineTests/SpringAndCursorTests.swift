import XCTest

@testable import MotionEngine
@testable import ProjectModel
@testable import TimelineCore

final class SpringAndCursorTests: XCTestCase {

    // MARK: - Spring integrator

    func testSpringConvergesAndIsDeterministic() {
        var a = SpringState2D(value: SIMD2(0, 0))
        var b = SpringState2D(value: SIMD2(0, 0))
        let target = SIMD2(100.0, 50.0)
        for _ in 0..<2000 {  // 2 s of 1 ms substeps
            SpringIntegrator.step(&a, target: target, parameters: .cursorNormal, dt: 0.001)
            SpringIntegrator.step(&b, target: target, parameters: .cursorNormal, dt: 0.001)
        }
        XCTAssertEqual(a, b)  // bit-for-bit deterministic
        XCTAssertEqual(a.value.x, 100, accuracy: 1.0)
        XCTAssertEqual(a.value.y, 50, accuracy: 1.0)
        XCTAssertLessThan(abs(a.velocity.x), 5)
    }

    func testSpringNeverDivergesForAllPresets() {
        for parameters in [
            SpringParameters.cursorNormal, .cursorQuickHop, .cursorHeld,
            .clickScale, .screenCamera,
        ] {
            var state = SpringState1D(value: 0)
            for step in 0..<5000 {
                let target: Double = step % 100 < 50 ? 1000 : -1000  // hostile square wave
                SpringIntegrator.step(&state, target: target, parameters: parameters, dt: 0.001)
                XCTAssertTrue(state.value.isFinite, "\(parameters) diverged at step \(step)")
            }
        }
    }

    // MARK: - Synthetic timeline

    private func makeTimeline(durationNs: Int64 = 6_000_000_000) -> MotionTimeline {
        var events: [EventRecord] = []
        var sequence: UInt64 = 1
        // Moves every 16 ms along a diagonal for the first 3 seconds.
        var timeNs: Int64 = 0
        while timeNs < 3_000_000_000 {
            let progress = Double(timeNs) / 3_000_000_000
            events.append(EventRecord(
                sequence: sequence, timeNs: timeNs, type: .cursorMove,
                displayID: 1, xPx: 100 + progress * 800, yPx: 100 + progress * 400,
                cursorID: "arrow-1", buttons: 0))
            sequence += 1
            timeNs += 16_000_000
        }
        // A click at 1 s.
        events.append(EventRecord(
            sequence: sequence, timeNs: 1_000_000_000, type: .mouseDown,
            displayID: 1, xPx: 366, yPx: 233, cursorID: "arrow-1", button: .left))
        sequence += 1
        events.append(EventRecord(
            sequence: sequence, timeNs: 1_080_000_000, type: .mouseUp,
            displayID: 1, xPx: 366, yPx: 233, cursorID: "arrow-1", button: .left))
        return MotionTimeline(events: events)
    }

    // MARK: - Cursor engine

    func testSeekEqualsPlayThrough() {
        let timeline = makeTimeline()
        let settings = CursorSettings()

        // Play through: query every frame sequentially.
        let sequential = CursorEngine(
            timeline: timeline, settings: settings, durationNs: 6_000_000_000)
        var playedState: CursorFrameState?
        var frame: Int64 = 0
        while frame * 33_333_333 <= 2_700_000_000 {
            playedState = sequential.state(at: frame * 33_333_333)
            frame += 1
        }

        // Cold seek on a fresh engine straight to the same time.
        let seeked = CursorEngine(
            timeline: timeline, settings: settings, durationNs: 6_000_000_000)
        let seekState = seeked.state(at: (frame - 1) * 33_333_333)

        XCTAssertEqual(playedState, seekState)
    }

    func testCursorFollowsTargetWithLag() {
        let timeline = makeTimeline()
        let engine = CursorEngine(
            timeline: timeline, settings: CursorSettings(), durationNs: 6_000_000_000)
        let state = try! XCTUnwrap(engine.state(at: 2_000_000_000))
        let target = try! XCTUnwrap(timeline.targetPosition(at: 2_000_000_000))
        // Smoothed cursor is near, but not exactly at, the moving target.
        XCTAssertEqual(state.position.x, target.x, accuracy: 60)
        XCTAssertEqual(state.position.y, target.y, accuracy: 40)
        // At 3 s the target stops; by 4 s the spring has settled onto it.
        let settled = try! XCTUnwrap(engine.state(at: 4_000_000_000))
        let finalTarget = try! XCTUnwrap(timeline.targetPosition(at: 4_000_000_000))
        XCTAssertEqual(settled.position.x, finalTarget.x, accuracy: 1.5)
        XCTAssertEqual(settled.position.y, finalTarget.y, accuracy: 1.5)
    }

    func testClickSquashDipsAndRecovers() {
        let timeline = makeTimeline()
        let engine = CursorEngine(
            timeline: timeline, settings: CursorSettings(), durationNs: 6_000_000_000)
        let during = try! XCTUnwrap(engine.state(at: 1_100_000_000))
        XCTAssertLessThan(during.scale, 0.97)
        let after = try! XCTUnwrap(engine.state(at: 2_500_000_000))
        XCTAssertEqual(after.scale, 1.0, accuracy: 0.03)
    }

    func testButtonDownStateAndRawMode() {
        let timeline = makeTimeline()
        var settings = CursorSettings()
        settings.smoothed = false
        let engine = CursorEngine(
            timeline: timeline, settings: settings, durationNs: 6_000_000_000)
        let held = try! XCTUnwrap(engine.state(at: 1_040_000_000))
        XCTAssertTrue(held.buttonDown)
        // Raw mode: exact recorded position.
        let raw = try! XCTUnwrap(engine.state(at: 2_000_000_000))
        XCTAssertEqual(raw.position, timeline.targetPosition(at: 2_000_000_000))
    }

    func testIdleHide() {
        let timeline = makeTimeline()
        var settings = CursorSettings()
        settings.idleHideAfterNs = 1_000_000_000
        let engine = CursorEngine(
            timeline: timeline, settings: settings, durationNs: 6_000_000_000)
        // Moves stop at 3 s; at 3.5 s still visible, at 4.5 s hidden.
        XCTAssertTrue(try! XCTUnwrap(engine.state(at: 3_500_000_000)).visible)
        XCTAssertFalse(try! XCTUnwrap(engine.state(at: 4_500_000_000)).visible)
    }

    func testEmptyTimelineYieldsNoCursor() {
        let engine = CursorEngine(
            timeline: MotionTimeline(events: []),
            settings: CursorSettings(),
            durationNs: 1_000_000_000)
        XCTAssertNil(engine.state(at: 500_000_000))
    }
}
