import CoreImage
import MotionEngine
import TimelineCore
import XCTest

@testable import RenderGraph

/// Camera PiP geometry and compositing: corner anchoring, zoom shrink,
/// shapes, mirroring, and the hidden switch — all through the same composer
/// preview and export share.
final class CameraPiPTests: XCTestCase {

    private let output = SIMD2(320.0, 180.0)
    private let source = SIMD2(320.0, 180.0)

    private func makeComposer(style: FrameStyle = .raw) -> FrameComposer {
        FrameComposer(style: style, outputSize: output, sourceSize: source)
    }

    // MARK: Geometry

    func testCameraRectAnchorsToEachCorner() {
        let composer = makeComposer()
        let cameraSize = SIMD2(640.0, 360.0)
        var style = CameraStyle(size: 0.25, margin: 0.05)
        let minEdge = 180.0
        let expectedWidth = 0.25 * minEdge
        let margin = 0.05 * minEdge

        style.corner = .topLeft
        var rect = composer.cameraRect(style: style, cameraSize: cameraSize, zoomScale: 1)
        XCTAssertEqual(rect.minX, margin, accuracy: 0.01)
        XCTAssertEqual(rect.minY, margin, accuracy: 0.01)
        XCTAssertEqual(rect.width, expectedWidth, accuracy: 0.01)
        // 16:9 camera keeps its aspect in a non-circle shape.
        XCTAssertEqual(rect.height, expectedWidth * 360 / 640, accuracy: 0.01)

        style.corner = .bottomRight
        rect = composer.cameraRect(style: style, cameraSize: cameraSize, zoomScale: 1)
        XCTAssertEqual(rect.maxX, output.x - margin, accuracy: 0.01)
        XCTAssertEqual(rect.maxY, output.y - margin, accuracy: 0.01)

        style.corner = .topRight
        rect = composer.cameraRect(style: style, cameraSize: cameraSize, zoomScale: 1)
        XCTAssertEqual(rect.maxX, output.x - margin, accuracy: 0.01)
        XCTAssertEqual(rect.minY, margin, accuracy: 0.01)

        style.corner = .bottomLeft
        rect = composer.cameraRect(style: style, cameraSize: cameraSize, zoomScale: 1)
        XCTAssertEqual(rect.minX, margin, accuracy: 0.01)
        XCTAssertEqual(rect.maxY, output.y - margin, accuracy: 0.01)
    }

    func testCameraShrinksDuringZoomAndStaysAnchored() {
        let composer = makeComposer()
        let cameraSize = SIMD2(640.0, 360.0)
        let style = CameraStyle(corner: .bottomRight, size: 0.3, zoomedScale: 0.7)

        let rest = composer.cameraRect(style: style, cameraSize: cameraSize, zoomScale: 1)
        let zoomed = composer.cameraRect(style: style, cameraSize: cameraSize, zoomScale: 2)
        // Fully shrunk by 1.5×: width scales by zoomedScale.
        XCTAssertEqual(zoomed.width, rest.width * 0.7, accuracy: 0.01)
        // The corner anchor (bottom-right) does not move.
        XCTAssertEqual(zoomed.maxX, rest.maxX, accuracy: 0.01)
        XCTAssertEqual(zoomed.maxY, rest.maxY, accuracy: 0.01)

        // Halfway (1.25×) sits between the two, so the shrink is continuous.
        let half = composer.cameraRect(style: style, cameraSize: cameraSize, zoomScale: 1.25)
        XCTAssertGreaterThan(half.width, zoomed.width)
        XCTAssertLessThan(half.width, rest.width)

        // zoomedScale of 1 disables the shrink entirely.
        let fixed = CameraStyle(corner: .bottomRight, size: 0.3, zoomedScale: 1.0)
        let fixedZoomed = composer.cameraRect(style: fixed, cameraSize: cameraSize, zoomScale: 3)
        let fixedRest = composer.cameraRect(style: fixed, cameraSize: cameraSize, zoomScale: 1)
        XCTAssertEqual(fixedZoomed.width, fixedRest.width, accuracy: 0.001)
    }

    func testCircleShapeIsSquareRegardlessOfCameraAspect() {
        let composer = makeComposer()
        let style = CameraStyle(size: 0.25, shape: .circle)
        let rect = composer.cameraRect(
            style: style, cameraSize: SIMD2(1920, 1080), zoomScale: 1)
        XCTAssertEqual(rect.width, rect.height, accuracy: 0.001)
    }

    // MARK: Pixels

    private func render(_ image: CIImage) -> [UInt8] {
        let context = CIContext(options: [
            .workingColorSpace: NSNull(), .outputColorSpace: NSNull(),
        ])
        let width = Int(output.x)
        let height = Int(output.y)
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        context.render(
            image, toBitmap: &pixels, rowBytes: width * 4,
            bounds: CGRect(x: 0, y: 0, width: width, height: height),
            format: .RGBA8, colorSpace: nil)
        return pixels
    }

    private func pixel(_ pixels: [UInt8], _ x: Int, _ y: Int) -> (UInt8, UInt8, UInt8) {
        let offset = (y * Int(output.x) + x) * 4
        return (pixels[offset], pixels[offset + 1], pixels[offset + 2])
    }

    private func composeFrame(cameraStyle: CameraStyle?) -> [UInt8] {
        let composer = makeComposer()
        let black = CIImage(color: CIColor(red: 0, green: 0, blue: 0))
            .cropped(to: CGRect(x: 0, y: 0, width: source.x, height: source.y))
        let green = CIImage(color: CIColor(red: 0, green: 1, blue: 0))
            .cropped(to: CGRect(x: 0, y: 0, width: 640, height: 360))
        let input = FrameComposer.Input(
            screenImage: black,
            camera: .identity,
            cameraImage: cameraStyle == nil ? nil : green,
            cameraStyle: cameraStyle)
        return render(composer.compose(input))
    }

    func testCameraPixelsAppearInChosenCornerOnly() {
        let style = CameraStyle(
            corner: .bottomRight, size: 0.3, shape: .square, margin: 0.05)
        let pixels = composeFrame(cameraStyle: style)

        // Inside the PiP (bottom-right corner region): green camera pixels.
        let inside = pixel(pixels, Int(output.x) - 20, Int(output.y) - 20)
        XCTAssertLessThan(inside.0, 60)
        XCTAssertGreaterThan(inside.1, 180)

        // Opposite corner stays screen-black.
        let outside = pixel(pixels, 20, 20)
        XCTAssertLessThan(outside.1, 40)
    }

    func testHiddenCameraLeavesNoTrace() {
        var style = CameraStyle(corner: .bottomRight, size: 0.3, shape: .square)
        style.hidden = true
        let pixels = composeFrame(cameraStyle: style)
        let corner = pixel(pixels, Int(output.x) - 20, Int(output.y) - 20)
        XCTAssertLessThan(corner.1, 40)

        let noCamera = composeFrame(cameraStyle: nil)
        let noCameraCorner = pixel(noCamera, Int(output.x) - 20, Int(output.y) - 20)
        XCTAssertLessThan(noCameraCorner.1, 40)
    }

    func testMirroredCameraFlipsHorizontally() {
        // Camera frame: left half red, right half blue.
        let red = CIImage(color: CIColor(red: 1, green: 0, blue: 0))
            .cropped(to: CGRect(x: 0, y: 0, width: 320, height: 360))
        let blue = CIImage(color: CIColor(red: 0, green: 0, blue: 1))
            .cropped(to: CGRect(x: 320, y: 0, width: 320, height: 360))
        let cameraFrame = red.composited(over: blue)

        func cornerPixels(mirrored: Bool) -> ((UInt8, UInt8, UInt8), (UInt8, UInt8, UInt8)) {
            let composer = makeComposer()
            let black = CIImage(color: CIColor(red: 0, green: 0, blue: 0))
                .cropped(to: CGRect(x: 0, y: 0, width: source.x, height: source.y))
            let style = CameraStyle(
                corner: .bottomRight, size: 0.3, shape: .square,
                margin: 0.05, mirrored: mirrored)
            let composed = composer.compose(FrameComposer.Input(
                screenImage: black, camera: .identity,
                cameraImage: cameraFrame, cameraStyle: style))
            let pixels = render(composed)
            let rect = composer.cameraRect(
                style: style, cameraSize: SIMD2(640, 360), zoomScale: 1)
            let y = Int(rect.midY)
            return (
                pixel(pixels, Int(rect.minX) + 4, y),
                pixel(pixels, Int(rect.maxX) - 4, y)
            )
        }

        let (leftPlain, _) = cornerPixels(mirrored: false)
        let (leftMirrored, _) = cornerPixels(mirrored: true)
        // Un-mirrored shows red (camera-left) on the PiP's left; mirrored
        // swaps it to blue.
        XCTAssertGreaterThan(leftPlain.0, 180)
        XCTAssertGreaterThan(leftMirrored.2, 180)
    }
}

extension CameraPiPTests {
    /// The mesh background: deterministic (same input → same bytes),
    /// regionally distinct (the two lights actually show), and stable
    /// across the legacy background cases.
    func testMeshBackgroundIsDeterministicAndRegional() {
        let style = FrameStyle(
            background: .mesh(
                base: .init(red: 0.1, green: 0.09, blue: 0.22),
                glow1: .init(red: 0.45, green: 0.3, blue: 0.9),
                glow2: .init(red: 0.1, green: 0.6, blue: 0.8)),
            padding: 0.4, cornerRadius: 0, shadowOpacity: 0, shadowRadius: 0)
        let composer = FrameComposer(
            style: style, outputSize: SIMD2(320, 180), sourceSize: SIMD2(320, 180))
        let black = CIImage(color: CIColor(red: 0, green: 0, blue: 0))
            .cropped(to: CGRect(x: 0, y: 0, width: 320, height: 180))
        let context = CIContext(options: [
            .workingColorSpace: NSNull(), .outputColorSpace: NSNull(),
        ])
        func render() -> [UInt8] {
            var pixels = [UInt8](repeating: 0, count: 320 * 180 * 4)
            context.render(
                composer.compose(.init(screenImage: black, camera: .identity)),
                toBitmap: &pixels, rowBytes: 320 * 4,
                bounds: CGRect(x: 0, y: 0, width: 320, height: 180),
                format: .RGBA8, colorSpace: nil)
            return pixels
        }
        let first = render()
        XCTAssertEqual(first, render(), "mesh must be deterministic")
        // Upper-left corner leans glow1 (violet: R>G), lower-right leans
        // glow2 (teal: B and G high) — the lights are regionally distinct.
        func rgb(_ pixels: [UInt8], _ x: Int, _ y: Int) -> (Int, Int, Int) {
            let offset = (y * 320 + x) * 4
            return (Int(pixels[offset]), Int(pixels[offset + 1]), Int(pixels[offset + 2]))
        }
        let upperLeft = rgb(first, 24, 24)
        let lowerRight = rgb(first, 296, 156)
        XCTAssertFalse(
            upperLeft.0 == lowerRight.0 && upperLeft.1 == lowerRight.1
                && upperLeft.2 == lowerRight.2,
            "mesh has no regional variation")
        XCTAssertGreaterThan(upperLeft.0 + upperLeft.2, 60, "glow1 not visible")
        XCTAssertGreaterThan(lowerRight.1 + lowerRight.2, 60, "glow2 not visible")
    }

    func testMeshBackgroundRoundTripsThroughCodable() throws {
        let style = FrameStyle(background: .mesh(
            base: .init(red: 0.1, green: 0.2, blue: 0.3),
            glow1: .init(red: 0.4, green: 0.5, blue: 0.6),
            glow2: .init(red: 0.7, green: 0.8, blue: 0.9)))
        let data = try JSONEncoder().encode(style)
        let decoded = try JSONDecoder().decode(FrameStyle.self, from: data)
        XCTAssertEqual(decoded.background, style.background)
    }
}

extension CameraPiPTests {
    /// Near-1 content scales (even-dimension rounding residue) must snap
    /// to EXACTLY 1 in geometry, so offsets/cursor math and the raster
    /// identity fast-path can never disagree (≈5 px misregistration at
    /// 2880 wide before the snap).
    func testNearIdentityContentScaleSnapsToExactlyOne() {
        let composer = FrameComposer(
            style: .raw,
            outputSize: SIMD2(2878, 1618),
            sourceSize: SIMD2(2880, 1620))
        let geometry = composer.geometry(camera: .identity)
        XCTAssertEqual(geometry.contentScale, 1.0)

        // A real scale is untouched.
        let halfComposer = FrameComposer(
            style: .raw,
            outputSize: SIMD2(1440, 810),
            sourceSize: SIMD2(2880, 1620))
        let halfGeometry = halfComposer.geometry(camera: .identity)
        XCTAssertEqual(halfGeometry.contentScale, 0.5, accuracy: 0.0001)
    }
}

extension CameraPiPTests {
    // MARK: Camera intro (fullscreen → corner PiP)

    func testIntroProgressZeroAspectFillsTheCanvas() {
        let composer = makeComposer()
        let style = CameraStyle(corner: .bottomRight, size: 0.24)
        let rect = composer.cameraRect(
            style: style, cameraSize: SIMD2(640, 360), zoomScale: 1,
            introProgress: 0)
        // Aspect-fill: covers the whole 320×180 canvas exactly (16:9 camera
        // on a 16:9 canvas).
        XCTAssertEqual(rect.minX, 0, accuracy: 0.01)
        XCTAssertEqual(rect.minY, 0, accuracy: 0.01)
        XCTAssertEqual(rect.width, 320, accuracy: 0.01)
        XCTAssertEqual(rect.height, 180, accuracy: 0.01)

        // A portrait camera still COVERS the canvas (crops vertically).
        let portrait = composer.cameraRect(
            style: style, cameraSize: SIMD2(1080, 1920), zoomScale: 1,
            introProgress: 0)
        XCTAssertLessThanOrEqual(portrait.minX, 0.01)
        XCTAssertLessThanOrEqual(portrait.minY, 0.01)
        XCTAssertGreaterThanOrEqual(portrait.maxX, 320 - 0.01)
        XCTAssertGreaterThanOrEqual(portrait.maxY, 180 - 0.01)
    }

    func testIntroProgressOneMatchesPlainPiPRect() {
        let composer = makeComposer()
        let style = CameraStyle(corner: .topLeft, size: 0.3)
        let plain = composer.cameraRect(
            style: style, cameraSize: SIMD2(640, 360), zoomScale: 1)
        let full = composer.cameraRect(
            style: style, cameraSize: SIMD2(640, 360), zoomScale: 1,
            introProgress: 1)
        XCTAssertEqual(plain, full)
    }

    func testIntroMidpointSitsBetweenFullscreenAndPiP() {
        let composer = makeComposer()
        let style = CameraStyle(corner: .bottomRight, size: 0.24)
        let cameraSize = SIMD2(640.0, 360.0)
        let start = composer.cameraRect(
            style: style, cameraSize: cameraSize, zoomScale: 1, introProgress: 0)
        let end = composer.cameraRect(
            style: style, cameraSize: cameraSize, zoomScale: 1, introProgress: 1)
        let mid = composer.cameraRect(
            style: style, cameraSize: cameraSize, zoomScale: 1, introProgress: 0.5)
        XCTAssertLessThan(mid.width, start.width)
        XCTAssertGreaterThan(mid.width, end.width)
        // Exactly halfway (composer is linear; easing lives upstream).
        XCTAssertEqual(
            mid.width, (start.width + end.width) / 2, accuracy: 0.01)
        XCTAssertEqual(
            mid.minX, (start.minX + end.minX) / 2, accuracy: 0.01)
    }

    func testIntroPixelsCoverTheCenterThenClearIt() {
        let style = CameraStyle(corner: .bottomRight, size: 0.24, shape: .rounded)
        let black = CIImage(color: CIColor(red: 0, green: 0, blue: 0))
            .cropped(to: CGRect(x: 0, y: 0, width: source.x, height: source.y))
        let green = CIImage(color: CIColor(red: 0, green: 1, blue: 0))
            .cropped(to: CGRect(x: 0, y: 0, width: 640, height: 360))

        func centerPixel(introProgress: Double) -> (UInt8, UInt8, UInt8) {
            let composer = makeComposer()
            var input = FrameComposer.Input(
                screenImage: black, camera: .identity,
                cameraImage: green, cameraStyle: style)
            input.cameraIntroProgress = introProgress
            let pixels = render(composer.compose(input))
            return pixel(pixels, Int(output.x) / 2, Int(output.y) / 2)
        }

        // During the intro the camera owns the center of the canvas…
        XCTAssertGreaterThan(centerPixel(introProgress: 0).1, 180)
        // …afterwards the screen does.
        XCTAssertLessThan(centerPixel(introProgress: 1).1, 40)
    }
}
