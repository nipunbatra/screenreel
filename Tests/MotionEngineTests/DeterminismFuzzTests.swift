import XCTest

@testable import MotionEngine
@testable import ProjectModel
@testable import TimelineCore

/// Tiny deterministic PRNG (SplitMix64) so fuzz cases are reproducible.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

final class DeterminismFuzzTests: XCTestCase {

    // MARK: - Random-seek determinism (ACCEPTANCE §3: 100 deterministic seeks)

    private func makeBusyTimeline(durationNs: Int64) -> MotionTimeline {
        var events: [EventRecord] = []
        var sequence: UInt64 = 1
        var rng = SplitMix64(seed: 7)
        var timeNs: Int64 = 0
        while timeNs < durationNs {
            events.append(EventRecord(
                sequence: sequence, timeNs: timeNs, type: .cursorMove,
                displayID: 1,
                xPx: Double.random(in: 0...1920, using: &rng),
                yPx: Double.random(in: 0...1080, using: &rng),
                cursorID: "arrow-1", buttons: 0))
            sequence += 1
            // Irregular cadence, including quick-hop-triggering bursts.
            timeNs += Int64.random(in: 8_000_000...220_000_000, using: &rng)
            if Int.random(in: 0..<12, using: &rng) == 0 {
                events.append(EventRecord(
                    sequence: sequence, timeNs: timeNs, type: .mouseDown,
                    displayID: 1, xPx: 100, yPx: 100, cursorID: "arrow-1", button: .left))
                sequence += 1
                events.append(EventRecord(
                    sequence: sequence, timeNs: timeNs + 90_000_000, type: .mouseUp,
                    displayID: 1, xPx: 100, yPx: 100, cursorID: "arrow-1", button: .left))
                sequence += 1
            }
        }
        return MotionTimeline(events: events)
    }

    func testHundredRandomSeeksEqualLinearPlayback() {
        let durationNs: Int64 = 12_000_000_000
        let timeline = makeBusyTimeline(durationNs: durationNs)
        let settings = CursorSettings()

        // Linear pass at frame cadence, sampling states along the way.
        let linearEngine = CursorEngine(
            timeline: timeline, settings: settings, durationNs: durationNs)
        var rng = SplitMix64(seed: 42)
        let seekTimes = (0..<100).map { _ in
            Int64.random(in: 0...durationNs, using: &rng)
        }
        var linearStates: [Int64: CursorFrameState] = [:]
        var frameNs: Int64 = 0
        var pending = seekTimes.sorted()
        while frameNs <= durationNs {
            _ = linearEngine.state(at: frameNs)
            while let next = pending.first, next <= frameNs + 33_333_333 {
                linearStates[next] = linearEngine.state(at: next)
                pending.removeFirst()
            }
            frameNs += 33_333_333
        }
        for remaining in pending {
            linearStates[remaining] = linearEngine.state(at: remaining)
        }

        // Every seek on a cold engine matches the played-through state.
        for timeNs in seekTimes {
            let cold = CursorEngine(
                timeline: timeline, settings: settings, durationNs: durationNs)
            XCTAssertEqual(
                cold.state(at: timeNs), linearStates[timeNs],
                "cold seek to \(timeNs) diverged")
        }
    }

    func testCameraColdSeeksMatchAfterMixedAccess() {
        let zooms = [
            ZoomSegment(startNs: 1_000_000_000, endNs: 3_000_000_000, scale: 2.2, focalX: 0.3, focalY: 0.4),
            ZoomSegment(startNs: 5_000_000_000, endNs: 6_500_000_000, scale: 1.6, instant: true),
            ZoomSegment(startNs: 8_000_000_000, endNs: 9_000_000_000, scale: 3.5, focalX: 0.8, focalY: 0.7),
        ]
        let durationNs: Int64 = 11_000_000_000
        var rng = SplitMix64(seed: 99)
        let warm = CameraEngine(zooms: zooms, durationNs: durationNs)
        // Hammer the warm engine with random access first.
        var probes: [Int64] = []
        for _ in 0..<60 {
            probes.append(Int64.random(in: 0...durationNs, using: &rng))
        }
        var warmStates: [Int64: CameraState] = [:]
        for timeNs in probes {
            warmStates[timeNs] = warm.state(at: timeNs)
        }
        // Cold engines agree at every probe regardless of access history.
        for timeNs in probes {
            let cold = CameraEngine(zooms: zooms, durationNs: durationNs)
            XCTAssertEqual(cold.state(at: timeNs), warmStates[timeNs])
        }
    }

    // MARK: - Zoom generator property fuzz (spec §6 invariants)

    func testZoomGeneratorInvariantsOverRandomInputs() {
        var rng = SplitMix64(seed: 2026)
        let policy = ZoomGenerator.Policy()
        for iteration in 0..<200 {
            let durationNs = Int64.random(in: 5_000_000_000...90_000_000_000, using: &rng)
            let clickCount = Int.random(in: 0...30, using: &rng)
            var events: [EventRecord] = []
            for index in 0..<clickCount {
                let timeNs = Int64.random(in: 0...durationNs, using: &rng)
                events.append(EventRecord(
                    sequence: UInt64(index + 1), timeNs: timeNs, type: .mouseDown,
                    displayID: 1,
                    xPx: Double.random(in: -50...2050, using: &rng),  // includes off-screen
                    yPx: Double.random(in: -50...1150, using: &rng),
                    cursorID: "a", button: .left))
            }
            let barrierCount = Int.random(in: 0...3, using: &rng)
            let barriers = (0..<barrierCount).map { _ in
                Int64.random(in: 0...durationNs, using: &rng)
            }.sorted()

            let zooms = ZoomGenerator.generate(
                timeline: MotionTimeline(events: events),
                durationNs: durationNs,
                discontinuities: barriers,
                sourceSize: SIMD2(2000, 1100),
                policy: policy)

            var previousEnd: Int64 = .min
            for zoom in zooms {
                let label = "iteration \(iteration)"
                XCTAssertLessThan(zoom.startNs, zoom.endNs, label)
                XCTAssertGreaterThanOrEqual(zoom.startNs, policy.minStartNs, label)
                XCTAssertLessThanOrEqual(
                    zoom.endNs, durationNs - policy.endMarginNs, label)
                XCTAssertGreaterThanOrEqual(zoom.startNs, previousEnd, "\(label): overlap")
                previousEnd = zoom.endNs
                XCTAssertEqual(zoom.origin, "generated", label)
                XCTAssertEqual(zoom.generatorVersion, ZoomGenerator.version, label)
                for barrier in barriers {
                    XCTAssertFalse(
                        zoom.startNs < barrier && zoom.endNs > barrier,
                        "\(label): zoom spans barrier \(barrier)")
                }
                // Focal always keeps the viewport inside the source.
                let half = 0.5 / zoom.scale
                XCTAssertGreaterThanOrEqual(zoom.focalX, half - 1e-9, label)
                XCTAssertLessThanOrEqual(zoom.focalX, 1 - half + 1e-9, label)
                XCTAssertGreaterThanOrEqual(zoom.focalY, half - 1e-9, label)
                XCTAssertLessThanOrEqual(zoom.focalY, 1 - half + 1e-9, label)
            }
        }
    }

    /// Generation is a pure function of its inputs.
    func testZoomGeneratorIsDeterministic() {
        var events: [EventRecord] = []
        for index in 0..<10 {
            events.append(EventRecord(
                sequence: UInt64(index + 1), timeNs: Int64(index) * 2_000_000_000,
                type: .mouseDown, displayID: 1,
                xPx: Double(index * 100), yPx: 500, cursorID: "a", button: .left))
        }
        let timeline = MotionTimeline(events: events)
        let first = ZoomGenerator.generate(
            timeline: timeline, durationNs: 30_000_000_000,
            discontinuities: [7_000_000_000], sourceSize: SIMD2(1000, 1000))
        let second = ZoomGenerator.generate(
            timeline: timeline, durationNs: 30_000_000_000,
            discontinuities: [7_000_000_000], sourceSize: SIMD2(1000, 1000))
        // IDs are fresh UUIDs; compare everything else.
        XCTAssertEqual(first.count, second.count)
        for (a, b) in zip(first, second) {
            XCTAssertEqual(a.startNs, b.startNs)
            XCTAssertEqual(a.endNs, b.endNs)
            XCTAssertEqual(a.scale, b.scale)
            XCTAssertEqual(a.focalX, b.focalX)
            XCTAssertEqual(a.focalY, b.focalY)
        }
    }
}
