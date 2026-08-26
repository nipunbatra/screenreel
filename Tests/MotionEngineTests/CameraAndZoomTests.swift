import XCTest

@testable import MotionEngine
@testable import ProjectModel
@testable import TimelineCore

final class CameraAndZoomTests: XCTestCase {

    // MARK: - Camera engine

    func testCameraSpringsIntoAndOutOfZoom() {
        let zoom = ZoomSegment(
            startNs: 2_000_000_000, endNs: 4_000_000_000,
            scale: 2.0, focalX: 0.3, focalY: 0.6)
        let camera = CameraEngine(zooms: [zoom], durationNs: 8_000_000_000)

        XCTAssertEqual(camera.state(at: 1_000_000_000).scale, 1.0, accuracy: 0.01)
        // Well inside the zoom the spring has settled.
        let inside = camera.state(at: 3_500_000_000)
        XCTAssertEqual(inside.scale, 2.0, accuracy: 0.05)
        XCTAssertEqual(inside.focal.x, 0.3, accuracy: 0.02)
        XCTAssertEqual(inside.focal.y, 0.6, accuracy: 0.02)
        // Well after the zoom it has returned.
        let after = camera.state(at: 6_500_000_000)
        XCTAssertEqual(after.scale, 1.0, accuracy: 0.05)
    }

    func testCameraSeekEqualsPlayThrough() {
        let zoom = ZoomSegment(
            startNs: 1_000_000_000, endNs: 3_000_000_000, scale: 1.8)
        let sequential = CameraEngine(zooms: [zoom], durationNs: 6_000_000_000)
        var played = CameraState.identity
        var frame: Int64 = 0
        while frame * 33_333_333 <= 2_400_000_000 {
            played = sequential.state(at: frame * 33_333_333)
            frame += 1
        }
        let seeked = CameraEngine(zooms: [zoom], durationNs: 6_000_000_000)
        XCTAssertEqual(seeked.state(at: (frame - 1) * 33_333_333), played)
    }

    func testInstantZoomSkipsSpring() {
        let zoom = ZoomSegment(
            startNs: 2_000_000_000, endNs: 4_000_000_000,
            scale: 3.0, focalX: 0.5, focalY: 0.5, instant: true)
        let camera = CameraEngine(zooms: [zoom], durationNs: 8_000_000_000)
        // Immediately after the boundary the state is already the target.
        let justAfter = camera.state(at: 2_002_000_000)
        XCTAssertEqual(justAfter.scale, 3.0, accuracy: 0.0001)
    }

    func testDisabledZoomIsIgnored() {
        let zoom = ZoomSegment(
            startNs: 1_000_000_000, endNs: 3_000_000_000, scale: 3.0, disabled: true)
        let camera = CameraEngine(zooms: [zoom], durationNs: 6_000_000_000)
        XCTAssertEqual(camera.state(at: 2_000_000_000).scale, 1.0, accuracy: 0.001)
    }

    func testZoomScaleClampedToSpecRange() {
        XCTAssertEqual(ZoomSegment(startNs: 0, endNs: 1, scale: 9).scale, 4.5)
        XCTAssertEqual(ZoomSegment(startNs: 0, endNs: 1, scale: 0.2).scale, 1.0)
    }

    // MARK: - Zoom generation (docs/MOTION_ENGINE.md §6 policy)

    private func timeline(clickTimesNs: [Int64], position: (Double, Double) = (500, 500)) -> MotionTimeline {
        var events: [EventRecord] = []
        for (index, time) in clickTimesNs.enumerated() {
            events.append(EventRecord(
                sequence: UInt64(index * 2 + 1), timeNs: time, type: .mouseDown,
                displayID: 1, xPx: position.0, yPx: position.1, cursorID: "a", button: .left))
            events.append(EventRecord(
                sequence: UInt64(index * 2 + 2), timeNs: time + 80_000_000, type: .mouseUp,
                displayID: 1, xPx: position.0, yPx: position.1, cursorID: "a", button: .left))
        }
        return MotionTimeline(events: events)
    }

    func testSingleClickCandidateRange() {
        let zooms = ZoomGenerator.generate(
            timeline: timeline(clickTimesNs: [5_000_000_000]),
            durationNs: 20_000_000_000,
            sourceSize: SIMD2(1000, 1000))
        XCTAssertEqual(zooms.count, 1)
        XCTAssertEqual(zooms[0].startNs, 4_700_000_000)  // click − 300 ms
        XCTAssertEqual(zooms[0].endNs, 7_500_000_000)  // click + 2500 ms
        XCTAssertEqual(zooms[0].origin, "generated")
        XCTAssertEqual(zooms[0].generatorVersion, ZoomGenerator.version)
    }

    func testClusteredClicksMerge() {
        let zooms = ZoomGenerator.generate(
            timeline: timeline(clickTimesNs: [1_000_000_000, 2_000_000_000, 3_000_000_000]),
            durationNs: 20_000_000_000,
            sourceSize: SIMD2(1000, 1000))
        XCTAssertEqual(zooms.count, 1)
        XCTAssertEqual(zooms[0].startNs, 700_000_000)
        XCTAssertEqual(zooms[0].endNs, 5_500_000_000)
    }

    func testFarApartClicksStaySeparate() {
        let zooms = ZoomGenerator.generate(
            timeline: timeline(clickTimesNs: [1_000_000_000, 12_000_000_000]),
            durationNs: 30_000_000_000,
            sourceSize: SIMD2(1000, 1000))
        XCTAssertEqual(zooms.count, 2)
    }

    func testClipTailClickIgnoredAndEndClamped() {
        // Click in the final second is ignored entirely.
        let ignored = ZoomGenerator.generate(
            timeline: timeline(clickTimesNs: [19_500_000_000]),
            durationNs: 20_000_000_000,
            sourceSize: SIMD2(1000, 1000))
        XCTAssertTrue(ignored.isEmpty)

        // A late-but-allowed click clamps its end to duration − 800 ms.
        let clamped = ZoomGenerator.generate(
            timeline: timeline(clickTimesNs: [18_500_000_000]),
            durationNs: 20_000_000_000,
            sourceSize: SIMD2(1000, 1000))
        XCTAssertEqual(clamped.count, 1)
        XCTAssertEqual(clamped[0].endNs, 19_200_000_000)
    }

    func testEarlyClickClampsStart() {
        let zooms = ZoomGenerator.generate(
            timeline: timeline(clickTimesNs: [100_000_000]),
            durationNs: 20_000_000_000,
            sourceSize: SIMD2(1000, 1000))
        XCTAssertEqual(zooms.first?.startNs, 1_000_000)  // >= 1 ms floor
    }

    func testDiscontinuityIsNeverSpanned() {
        let zooms = ZoomGenerator.generate(
            timeline: timeline(clickTimesNs: [2_000_000_000, 3_000_000_000]),
            durationNs: 20_000_000_000,
            discontinuities: [2_500_000_000],
            sourceSize: SIMD2(1000, 1000))
        XCTAssertEqual(zooms.count, 2)
        guard zooms.count == 2 else { return }
        XCTAssertEqual(zooms[0].endNs, 2_500_000_000)
        XCTAssertGreaterThanOrEqual(zooms[1].startNs, 2_500_000_000)
        for zoom in zooms {
            XCTAssertFalse(zoom.startNs < 2_500_000_000 && zoom.endNs > 2_500_000_000)
        }
    }

    // MARK: - Focal points (spec §7)

    func testFocalPointCenterClampAndSnap() {
        // Center click stays centered.
        let center = ZoomGenerator.focalPoint(
            clicks: [.init(timeNs: 0, position: SIMD2(500, 500))],
            sourceSize: SIMD2(1000, 1000), scale: 2, snapRatio: 0.25)
        XCTAssertEqual(center, SIMD2(0.5, 0.5))

        // Near-corner click snaps to the edge-flush focal.
        let corner = ZoomGenerator.focalPoint(
            clicks: [.init(timeNs: 0, position: SIMD2(100, 100))],
            sourceSize: SIMD2(1000, 1000), scale: 2, snapRatio: 0.25)
        XCTAssertEqual(corner, SIMD2(0.25, 0.25))  // half-viewport at 2×

        // Cluster uses the bounding-box center.
        let cluster = ZoomGenerator.focalPoint(
            clicks: [
                .init(timeNs: 0, position: SIMD2(400, 600)),
                .init(timeNs: 1, position: SIMD2(600, 400)),
            ],
            sourceSize: SIMD2(1000, 1000), scale: 2, snapRatio: 0.25)
        XCTAssertEqual(cluster, SIMD2(0.5, 0.5))
    }

    func testClampNeverRevealsBeyondSource() {
        for x in stride(from: 0.0, through: 1.0, by: 0.05) {
            for scale in [1.0, 1.5, 2.0, 4.5] {
                let focal = ZoomGenerator.clampFocal(
                    SIMD2(x, 1 - x), scale: scale, snapRatio: 0)
                let half = 0.5 / scale
                XCTAssertGreaterThanOrEqual(focal.x, half - 1e-9)
                XCTAssertLessThanOrEqual(focal.x, 1 - half + 1e-9)
            }
        }
    }
}
