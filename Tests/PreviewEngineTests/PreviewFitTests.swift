import CoreGraphics
import XCTest

@testable import PreviewEngine

/// The Metal preview surface derives pointer→canvas fractions from the
/// canvas size and its own bounds (there is no CGImage to measure any more).
/// These pin that math: it must agree with the aspect-fit the old
/// `Image(...).aspectRatio(.fit)` path produced.
final class PreviewFitTests: XCTestCase {

    func testExactFitIsIdentity() {
        let rect = PreviewFit.fittedRect(
            canvasSize: SIMD2(1920, 1080), container: SIMD2(1920, 1080))
        XCTAssertEqual(rect, CGRect(x: 0, y: 0, width: 1920, height: 1080))
        let fraction = PreviewFit.fraction(
            of: CGPoint(x: 480, y: 810),
            canvasSize: SIMD2(1920, 1080), container: CGSize(width: 1920, height: 1080))
        XCTAssertEqual(fraction?.x ?? -1, 0.25, accuracy: 1e-9)
        XCTAssertEqual(fraction?.y ?? -1, 0.75, accuracy: 1e-9)
    }

    func testLetterboxCentersAndRejectsBars() {
        // 16:9 canvas in a square container: bars above and below.
        let rect = PreviewFit.fittedRect(
            canvasSize: SIMD2(1600, 900), container: SIMD2(800, 800))
        XCTAssertEqual(rect, CGRect(x: 0, y: 175, width: 800, height: 450))
        XCTAssertNil(PreviewFit.fraction(
            of: CGPoint(x: 400, y: 100),
            canvasSize: SIMD2(1600, 900), container: CGSize(width: 800, height: 800)))
        XCTAssertNil(PreviewFit.fraction(
            of: CGPoint(x: 400, y: 700),
            canvasSize: SIMD2(1600, 900), container: CGSize(width: 800, height: 800)))
        let inside = PreviewFit.fraction(
            of: CGPoint(x: 600, y: 175 + 112.5),
            canvasSize: SIMD2(1600, 900), container: CGSize(width: 800, height: 800))
        XCTAssertEqual(inside?.x ?? -1, 0.75, accuracy: 1e-9)
        XCTAssertEqual(inside?.y ?? -1, 0.25, accuracy: 1e-9)
    }

    func testPillarboxCentersHorizontally() {
        // Portrait canvas in a wide container: bars left and right.
        let rect = PreviewFit.fittedRect(
            canvasSize: SIMD2(900, 1600), container: SIMD2(1000, 400))
        XCTAssertEqual(rect, CGRect(x: 387.5, y: 0, width: 225, height: 400))
        XCTAssertNil(PreviewFit.fraction(
            of: CGPoint(x: 10, y: 200),
            canvasSize: SIMD2(900, 1600), container: CGSize(width: 1000, height: 400)))
        let corner = PreviewFit.fraction(
            of: CGPoint(x: 387.5 + 225, y: 400),
            canvasSize: SIMD2(900, 1600), container: CGSize(width: 1000, height: 400))
        XCTAssertEqual(corner?.x ?? -1, 1, accuracy: 1e-9)
        XCTAssertEqual(corner?.y ?? -1, 1, accuracy: 1e-9)
    }

    func testDegenerateSizesReturnNil() {
        XCTAssertNil(PreviewFit.fittedRect(canvasSize: SIMD2(0, 1080), container: SIMD2(800, 600)))
        XCTAssertNil(PreviewFit.fittedRect(canvasSize: SIMD2(1920, 1080), container: SIMD2(800, 0)))
        XCTAssertNil(PreviewFit.fraction(
            of: .zero, canvasSize: SIMD2(1, 1), container: CGSize(width: -5, height: 5)))
        XCTAssertEqual(
            PreviewFit.transform(canvasSize: SIMD2(0, 0), drawableSize: SIMD2(100, 100)),
            .identity)
    }

    func testTransformMapsCanvasCornersOntoFittedRect() {
        // Half-res 4K canvas rendered into a Retina drawable of a different
        // aspect: the canvas corners must land on the fitted rect's corners.
        let canvas = SIMD2<Double>(2048, 1152)
        let drawable = SIMD2<Double>(3000, 2000)
        let transform = PreviewFit.transform(canvasSize: canvas, drawableSize: drawable)
        let fitted = PreviewFit.fittedRect(canvasSize: canvas, container: drawable)!
        let origin = CGPoint.zero.applying(transform)
        let far = CGPoint(x: canvas.x, y: canvas.y).applying(transform)
        XCTAssertEqual(origin.x, fitted.minX, accuracy: 1e-9)
        XCTAssertEqual(origin.y, fitted.minY, accuracy: 1e-9)
        XCTAssertEqual(far.x, fitted.maxX, accuracy: 1e-9)
        XCTAssertEqual(far.y, fitted.maxY, accuracy: 1e-9)
        // Uniform scale: no distortion.
        XCTAssertEqual(transform.a, transform.d, accuracy: 1e-12)
        XCTAssertEqual(transform.b, 0)
        XCTAssertEqual(transform.c, 0)
    }

    func testFractionMatchesLegacyImageFraction() {
        // The retired EditorView.imageFraction(point:container:image:) used
        // exactly this fit; a regression here would silently mis-aim zooms.
        func legacy(point: CGPoint, container: CGSize, image: CGSize) -> CGPoint? {
            let scale = min(container.width / image.width, container.height / image.height)
            let shown = CGSize(width: image.width * scale, height: image.height * scale)
            let origin = CGPoint(
                x: (container.width - shown.width) / 2,
                y: (container.height - shown.height) / 2)
            let local = CGPoint(x: point.x - origin.x, y: point.y - origin.y)
            guard local.x >= 0, local.y >= 0,
                local.x <= shown.width, local.y <= shown.height
            else { return nil }
            return CGPoint(x: local.x / shown.width, y: local.y / shown.height)
        }
        let container = CGSize(width: 1234, height: 777)
        let canvas = SIMD2<Double>(4096, 2304)
        for (x, y) in [(10.0, 10.0), (617.0, 388.0), (1200.0, 700.0), (300.0, 60.0), (1233.0, 776.0)] {
            let point = CGPoint(x: x, y: y)
            let expected = legacy(
                point: point, container: container,
                image: CGSize(width: canvas.x, height: canvas.y))
            let actual = PreviewFit.fraction(of: point, canvasSize: canvas, container: container)
            XCTAssertEqual(actual == nil, expected == nil, "nil-ness differs at \(point)")
            if let expected, let actual {
                XCTAssertEqual(actual.x, expected.x, accuracy: 1e-12)
                XCTAssertEqual(actual.y, expected.y, accuracy: 1e-12)
            }
        }
    }
}
