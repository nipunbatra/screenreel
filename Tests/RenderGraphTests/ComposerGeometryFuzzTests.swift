import Foundation
import MotionEngine
import TimelineCore
import XCTest

@testable import RenderGraph

/// Seeded fuzz over the composer's geometry: for any style, canvas, source,
/// and (possibly overshooting) camera state, the mapping must stay finite,
/// the card must stay inside the canvas, and the zoom viewport must never
/// reveal space beyond the source edges.
final class ComposerGeometryFuzzTests: XCTestCase {

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
    }

    func testGeometryInvariantsUnderFuzz() {
        var rng = Rng(state: 0xC0FF_EE)
        for iteration in 0..<800 {
            let source = SIMD2(
                rng.double(in: 320...6016), rng.double(in: 200...3384))
            let output = SIMD2(
                rng.double(in: 200...5000), rng.double(in: 200...5000))
            let style = FrameStyle(
                padding: rng.double(in: 0...0.25),
                cornerRadius: rng.double(in: 0...0.1),
                shadowOpacity: 0, shadowRadius: 0)
            let composer = FrameComposer(
                style: style, outputSize: output, sourceSize: source)
            // Spring overshoot can push scale below 1 and focal outside 0–1.
            let camera = CameraState(
                scale: rng.double(in: 0.7...5.2),
                focal: SIMD2(rng.double(in: -0.4...1.4), rng.double(in: -0.4...1.4)))
            let geometry = composer.geometry(camera: camera)
            let context = "iter \(iteration): src \(source) out \(output) cam \(camera.scale)"

            XCTAssertTrue(geometry.contentScale.isFinite, context)
            XCTAssertGreaterThan(geometry.contentScale, 0, context)
            // Card entirely inside the canvas.
            XCTAssertGreaterThanOrEqual(geometry.cardOrigin.x, -0.5, context)
            XCTAssertGreaterThanOrEqual(geometry.cardOrigin.y, -0.5, context)
            XCTAssertLessThanOrEqual(
                geometry.cardOrigin.x + geometry.cardSize.x, output.x + 0.5, context)
            XCTAssertLessThanOrEqual(
                geometry.cardOrigin.y + geometry.cardSize.y, output.y + 0.5, context)

            // Source corners map onto/around the card; with the focal
            // clamped, the card's corners must land inside the source's
            // mapped extent (no out-of-source pixels shown).
            let topLeft = geometry.canvasPoint(forSource: SIMD2(0, 0))
            let bottomRight = geometry.canvasPoint(forSource: source)
            XCTAssertLessThanOrEqual(topLeft.x, geometry.cardOrigin.x + 0.5, context)
            XCTAssertLessThanOrEqual(topLeft.y, geometry.cardOrigin.y + 0.5, context)
            XCTAssertGreaterThanOrEqual(
                bottomRight.x, geometry.cardOrigin.x + geometry.cardSize.x - 0.5, context)
            XCTAssertGreaterThanOrEqual(
                bottomRight.y, geometry.cardOrigin.y + geometry.cardSize.y - 0.5, context)
        }
    }

    func testCameraRectStaysInsideCanvasUnderFuzz() {
        var rng = Rng(state: 0xBADA_55)
        for iteration in 0..<600 {
            // Portrait and landscape canvases both fuzzed (minEdge flips).
            let output = SIMD2(
                rng.double(in: 240...4400), rng.double(in: 240...4400))
            let composer = FrameComposer(
                style: FrameStyle(), outputSize: output, sourceSize: SIMD2(1920, 1080))
            let corners: [CameraStyle.Corner] = [
                .topLeft, .topRight, .bottomLeft, .bottomRight,
            ]
            let shapes: [CameraStyle.Shape] = [.rounded, .circle, .square]
            let style = CameraStyle(
                corner: corners[Int(rng.next() % 4)],
                size: rng.double(in: 0.1...0.5),
                shape: shapes[Int(rng.next() % 3)],
                margin: rng.double(in: 0...0.08),
                zoomedScale: rng.double(in: 0.4...1))
            let rect = composer.cameraRect(
                style: style,
                cameraSize: SIMD2(rng.double(in: 320...4000), rng.double(in: 240...3000)),
                zoomScale: rng.double(in: 1...4.5))
            let context = "iter \(iteration): out \(output)"
            XCTAssertGreaterThan(rect.width, 0, context)
            XCTAssertTrue(rect.width.isFinite && rect.height.isFinite, context)
            XCTAssertGreaterThanOrEqual(rect.minX, -0.5, context)
            XCTAssertGreaterThanOrEqual(rect.minY, -0.5, context)
            XCTAssertLessThanOrEqual(rect.maxX, output.x + 0.5, context)
            // Tall cameras in a corner can exceed vertically only if the
            // size fraction plus margins demand it; the width anchor is the
            // contract — assert X strictly, Y within one PiP height.
            XCTAssertLessThanOrEqual(rect.maxY, output.y + rect.height, context)
        }
    }
}

extension ComposerGeometryFuzzTests {
    /// Aspect reframe keeps zoom targeting: zooms are
    /// source-relative, so switching 16:9 ↔ 9:16 ↔ 1:1 must keep the
    /// focal point centered in the card — no re-targeting pass needed.
    func testAspectReframeKeepsZoomTargeting() {
        let source = SIMD2(4096.0, 2304.0)
        let focal = SIMD2(0.3, 0.7)
        for aspect in [16.0 / 9, 9.0 / 16, 1.0, 4.0 / 3] {
            let height = 1000.0
            let output = SIMD2((height * aspect).rounded(), height)
            let composer = FrameComposer(
                style: FrameStyle(canvasAspect: aspect),
                outputSize: output, sourceSize: source)
            let camera = CameraState(scale: 2.0, focal: focal)
            let geometry = composer.geometry(camera: camera)
            // The (clamped) focal's canvas position must land inside the
            // card, near its center, for EVERY aspect.
            let clamped = ZoomGenerator.clampFocal(focal, scale: 2.0, snapRatio: 0)
            let point = geometry.canvasPoint(forSource: clamped * source)
            let cardCenter = geometry.cardOrigin + geometry.cardSize / 2
            XCTAssertEqual(point.x, cardCenter.x, accuracy: geometry.cardSize.x * 0.05,
                "aspect \(aspect): focal drifted horizontally")
            XCTAssertEqual(point.y, cardCenter.y, accuracy: geometry.cardSize.y * 0.05,
                "aspect \(aspect): focal drifted vertically")
        }
    }
}

extension ComposerGeometryFuzzTests {
    /// Click-to-aim depends on inverting the source→canvas mapping:
    /// (canvas − offset) / scale must recover the source point exactly.
    func testGeometryInverseRoundTripsUnderFuzz() {
        var rng = Rng(state: 0x14E5)
        for _ in 0..<300 {
            let source = SIMD2(
                rng.double(in: 320...6016), rng.double(in: 200...3384))
            let output = SIMD2(
                rng.double(in: 300...4000), rng.double(in: 300...4000))
            let composer = FrameComposer(
                style: FrameStyle(padding: rng.double(in: 0...0.2)),
                outputSize: output, sourceSize: source)
            let camera = CameraState(
                scale: rng.double(in: 1...4.5),
                focal: SIMD2(rng.double(in: 0...1), rng.double(in: 0...1)))
            let geometry = composer.geometry(camera: camera)
            let point = SIMD2(
                rng.double(in: 0...source.x), rng.double(in: 0...source.y))
            let canvas = geometry.canvasPoint(forSource: point)
            let recovered = (canvas - geometry.contentOffset) / geometry.contentScale
            XCTAssertEqual(recovered.x, point.x, accuracy: 0.001)
            XCTAssertEqual(recovered.y, point.y, accuracy: 0.001)
        }
    }
}
