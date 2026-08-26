import CoreGraphics
import Foundation
import XCTest

@testable import CaptureCore

/// Seeded property fuzz over the source-selection math: whatever a display
/// reports and whatever the user drags, the resolved capture must be legal
/// (even dimensions ≥ 2, area inside the display, finite non-negative
/// offsets).
final class GeometryFuzzTests: XCTestCase {

    /// SplitMix64 — deterministic across runs.
    private struct Rng {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        mutating func double(in range: ClosedRange<Double>) -> Double {
            let unit = Double(next() >> 11) / Double(1 << 53)
            return range.lowerBound + unit * (range.upperBound - range.lowerBound)
        }
        mutating func int(in range: ClosedRange<Int>) -> Int {
            range.lowerBound + Int(next() % UInt64(range.upperBound - range.lowerBound + 1))
        }
    }

    func testAreaResolutionInvariantsHoldForHostileInputs() {
        var rng = Rng(state: 0xA5A5_2026)
        for iteration in 0..<600 {
            let displayW = rng.int(in: 640...6016)
            let displayH = rng.int(in: 400...3384)
            let scale = [1.0, 2.0, 1.6, 2.5][rng.int(in: 0...3)]
            let requested = AreaRect(
                x: rng.double(in: -4000...8000),
                y: rng.double(in: -4000...8000),
                width: rng.double(in: -500...9000),
                height: rng.double(in: -500...9000))
            let resolved = SourceGeometry.area(
                requested: requested,
                displayWidthPoints: displayW, displayHeightPoints: displayH,
                scale: scale)
            let context = "iter \(iteration): \(requested) on \(displayW)×\(displayH)@\(scale)"

            XCTAssertGreaterThanOrEqual(resolved.widthPx, 2, context)
            XCTAssertGreaterThanOrEqual(resolved.heightPx, 2, context)
            XCTAssertEqual(resolved.widthPx % 2, 0, context)
            XCTAssertEqual(resolved.heightPx % 2, 0, context)
            let rect = resolved.areaRect!
            XCTAssertGreaterThanOrEqual(rect.x, 0, context)
            XCTAssertGreaterThanOrEqual(rect.y, 0, context)
            XCTAssertLessThanOrEqual(rect.x + rect.width, Double(displayW) + 0.001, context)
            XCTAssertLessThanOrEqual(rect.y + rect.height, Double(displayH) + 0.001, context)
            XCTAssertGreaterThanOrEqual(resolved.eventOffsetXPx, 0, context)
            XCTAssertGreaterThanOrEqual(resolved.eventOffsetYPx, 0, context)
            XCTAssertTrue(resolved.eventOffsetXPx.isFinite, context)
        }
    }

    func testWindowResolutionInvariantsAcrossDisplayArrangements() {
        var rng = Rng(state: 0x0FF1_CE)
        for iteration in 0..<400 {
            // Secondary displays can sit at negative global origins.
            let displayOrigin = CGPoint(
                x: rng.double(in: -5000...5000), y: rng.double(in: -3000...3000))
            let displayBounds = CGRect(
                origin: displayOrigin,
                size: CGSize(
                    width: rng.double(in: 800...5120),
                    height: rng.double(in: 600...2880)))
            let frame = CGRect(
                x: displayOrigin.x + rng.double(in: 0...600),
                y: displayOrigin.y + rng.double(in: 0...400),
                width: rng.double(in: 200...2000),
                height: rng.double(in: 150...1400))
            let scale = [1.0, 2.0][rng.int(in: 0...1)]
            let resolved = SourceGeometry.window(
                frame: frame, displayBounds: displayBounds, scale: scale)
            let context = "iter \(iteration)"
            XCTAssertEqual(resolved.widthPx % 2, 0, context)
            XCTAssertGreaterThanOrEqual(resolved.widthPx, 2, context)
            // Window inside its display ⇒ non-negative display-local offset.
            XCTAssertGreaterThanOrEqual(resolved.eventOffsetXPx, 0, context)
            XCTAssertGreaterThanOrEqual(resolved.eventOffsetYPx, 0, context)
            // The offset must be exactly the window's position in capture px.
            XCTAssertEqual(
                resolved.eventOffsetXPx,
                (frame.minX - displayBounds.minX) * scale,
                accuracy: 0.001, context)
        }
    }

    func testDisplayResolutionNeverProducesOddOrZeroDims() {
        var rng = Rng(state: 42)
        for _ in 0..<300 {
            let resolved = SourceGeometry.display(
                widthPoints: rng.int(in: 0...6016),
                heightPoints: rng.int(in: 0...3384),
                scale: rng.double(in: 0.5...3))
            XCTAssertGreaterThanOrEqual(resolved.widthPx, 2)
            XCTAssertEqual(resolved.widthPx % 2, 0)
            XCTAssertEqual(resolved.heightPx % 2, 0)
        }
    }
}
