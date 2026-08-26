import XCTest

@testable import MotionEngine

/// Click-ripple evaluation: pure, deterministic source-time math.
final class ClickRipplesTests: XCTestCase {

    private func click(_ tNs: Int64, x: Double = 100, y: Double = 50)
        -> MotionTimeline.Click
    {
        MotionTimeline.Click(timeNs: tNs, position: SIMD2(x, y))
    }

    func testRippleLifecycleWindow() {
        let downs = [click(1_000_000_000)]
        // Before the click: nothing.
        XCTAssertTrue(ClickRipples.active(downs: downs, atSource: 999_999_999).isEmpty)
        // At the click: progress 0.
        let atClick = ClickRipples.active(downs: downs, atSource: 1_000_000_000)
        XCTAssertEqual(atClick.count, 1)
        XCTAssertEqual(atClick[0].progress, 0, accuracy: 0.0001)
        XCTAssertEqual(atClick[0].position, SIMD2(100, 50))
        // Mid-life.
        let mid = ClickRipples.active(downs: downs, atSource: 1_225_000_000)
        XCTAssertEqual(mid[0].progress, 0.5, accuracy: 0.001)
        // Exactly at expiry: gone (window is exclusive at the start).
        XCTAssertTrue(
            ClickRipples.active(downs: downs, atSource: 1_450_000_000).isEmpty)
    }

    func testOverlappingClicksAllRippleOldestFirst() {
        let downs = [click(1_000_000_000), click(1_200_000_000, x: 200)]
        let active = ClickRipples.active(downs: downs, atSource: 1_300_000_000)
        XCTAssertEqual(active.count, 2)
        XCTAssertGreaterThan(active[0].progress, active[1].progress)
        XCTAssertEqual(active[1].position.x, 200)
    }

    func testBinarySearchMatchesLinearReference() {
        var downs: [MotionTimeline.Click] = []
        var seed: UInt64 = 0x9E3779B97F4A7C15
        var t: Int64 = 0
        for _ in 0..<500 {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            t += Int64(seed % 900_000_000)
            downs.append(click(t))
        }
        for probe in stride(from: Int64(0), to: t + 1_000_000_000, by: 37_777_777_777) {
            let fast = ClickRipples.active(downs: downs, atSource: probe)
            let slow = downs.filter {
                $0.timeNs <= probe && probe - $0.timeNs < ClickRipples.defaultDurationNs
            }.prefix(8)
            XCTAssertEqual(fast.count, slow.count, "at probe \(probe)")
        }
    }

    func testAtMostEightSimultaneousRipples() {
        let downs = (0..<20).map { click(Int64($0) * 10_000_000) }
        let active = ClickRipples.active(downs: downs, atSource: 200_000_000)
        XCTAssertLessThanOrEqual(active.count, 8)
    }
}
