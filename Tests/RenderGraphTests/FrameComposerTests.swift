import CoreImage
import XCTest

@testable import MotionEngine
@testable import RenderGraph
@testable import TimelineCore

final class FrameComposerTests: XCTestCase {

    // MARK: - Geometry (pure math)

    func testGeometryCentersCardAndScalesContent() {
        let composer = FrameComposer(
            style: FrameStyle(padding: 0.05, cornerRadius: 0, shadowOpacity: 0, shadowRadius: 0),
            outputSize: SIMD2(1920, 1080),
            sourceSize: SIMD2(1600, 900))
        let identity = composer.geometry(camera: .identity)

        // Card centered, inside the canvas, honoring the padding.
        XCTAssertEqual(identity.cardOrigin.x + identity.cardSize.x / 2, 960, accuracy: 0.001)
        XCTAssertEqual(identity.cardOrigin.y + identity.cardSize.y / 2, 540, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(identity.cardOrigin.y, 0.05 * 1080 - 0.001)
        // Source aspect preserved.
        XCTAssertEqual(
            identity.cardSize.x / identity.cardSize.y, 1600.0 / 900.0, accuracy: 0.001)
        // At identity camera the whole source maps exactly onto the card.
        let topLeft = identity.canvasPoint(forSource: SIMD2(0, 0))
        XCTAssertEqual(topLeft.x, identity.cardOrigin.x, accuracy: 0.001)
        XCTAssertEqual(topLeft.y, identity.cardOrigin.y, accuracy: 0.001)

        // Zooming 2× doubles the content scale but never moves the card.
        let zoomed = composer.geometry(camera: CameraState(scale: 2, focal: SIMD2(0.5, 0.5)))
        XCTAssertEqual(zoomed.contentScale, identity.contentScale * 2, accuracy: 0.001)
        XCTAssertEqual(zoomed.cardOrigin, identity.cardOrigin)
        XCTAssertEqual(zoomed.cardSize, identity.cardSize)
        // The focal point stays at the card center.
        let focalOnCanvas = zoomed.canvasPoint(forSource: SIMD2(800, 450))
        XCTAssertEqual(focalOnCanvas.x, 960, accuracy: 0.001)
        XCTAssertEqual(focalOnCanvas.y, 540, accuracy: 0.001)
    }

    func testGeometryClampsOvershootingFocal() {
        let composer = FrameComposer(
            style: .raw, outputSize: SIMD2(1000, 1000), sourceSize: SIMD2(1000, 1000))
        // A focal far past the edge (spring overshoot) must not reveal space
        // beyond the source: the viewport stays inside [0, source].
        let geometry = composer.geometry(
            camera: CameraState(scale: 2, focal: SIMD2(1.4, -0.3)))
        let sourceTopLeft = geometry.canvasPoint(forSource: SIMD2(0, 0))
        let sourceBottomRight = geometry.canvasPoint(forSource: SIMD2(1000, 1000))
        XCTAssertLessThanOrEqual(sourceTopLeft.x, geometry.cardOrigin.x + 0.001)
        XCTAssertGreaterThanOrEqual(
            sourceBottomRight.x, geometry.cardOrigin.x + geometry.cardSize.x - 0.001)
    }

    // MARK: - Pixel rendering

    private func render(_ image: CIImage, size: SIMD2<Double>) -> [UInt8] {
        let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
        let width = Int(size.x)
        let height = Int(size.y)
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        context.render(
            image,
            toBitmap: &pixels,
            rowBytes: width * 4,
            bounds: CGRect(x: 0, y: 0, width: width, height: height),
            format: .RGBA8,
            colorSpace: nil)
        return pixels
    }

    /// RGBA at a top-left-origin pixel coordinate. CIContext's toBitmap
    /// render writes row 0 as the top of the image, so no flip is needed.
    private func pixel(_ pixels: [UInt8], _ x: Int, _ y: Int, width: Int, height: Int) -> (UInt8, UInt8, UInt8, UInt8) {
        let offset = (y * width + x) * 4
        return (pixels[offset], pixels[offset + 1], pixels[offset + 2], pixels[offset + 3])
    }

    func testComposedFramePixels() {
        let output = SIMD2(320.0, 180.0)
        let source = SIMD2(320.0, 180.0)
        let composer = FrameComposer(
            style: FrameStyle(
                background: .solid(.init(red: 1, green: 0, blue: 0)),
                padding: 0.1, cornerRadius: 0, shadowOpacity: 0, shadowRadius: 0),
            outputSize: output,
            sourceSize: source)

        let white = CIImage(color: CIColor(red: 1, green: 1, blue: 1))
            .cropped(to: CGRect(x: 0, y: 0, width: source.x, height: source.y))
        let composed = composer.compose(.init(screenImage: white, camera: .identity))
        let pixels = render(composed, size: output)

        // Canvas corner (outside the padded card) is background red.
        let corner = pixel(pixels, 2, 2, width: 320, height: 180)
        XCTAssertGreaterThan(corner.0, 200)
        XCTAssertLessThan(corner.1, 50)

        // Canvas center is the white screen content.
        let center = pixel(pixels, 160, 90, width: 320, height: 180)
        XCTAssertGreaterThan(center.0, 200)
        XCTAssertGreaterThan(center.1, 200)
        XCTAssertGreaterThan(center.2, 200)
    }

    func testCursorSpriteIsDrawnAtAnchor() {
        let output = SIMD2(320.0, 180.0)
        let composer = FrameComposer(
            style: FrameStyle(
                background: .solid(.init(red: 0, green: 0, blue: 1)),
                padding: 0, cornerRadius: 0, shadowOpacity: 0, shadowRadius: 0),
            outputSize: output,
            sourceSize: output)

        let white = CIImage(color: CIColor(red: 1, green: 1, blue: 1))
            .cropped(to: CGRect(x: 0, y: 0, width: 320, height: 180))
        let blackSprite = CIImage(color: CIColor(red: 0, green: 0, blue: 0))
            .cropped(to: CGRect(x: 0, y: 0, width: 8, height: 8))
        let cursor = CursorFrameState(
            position: SIMD2(160, 90), scale: 1, cursorID: "a",
            visible: true, buttonDown: false)
        let composed = composer.compose(.init(
            screenImage: white,
            camera: .identity,
            cursor: cursor,
            cursorSprite: blackSprite,
            cursorHotspot: SIMD2(0, 0),
            cursorSpriteSourceSize: SIMD2(8, 8)))
        let pixels = render(composed, size: output)

        // A few pixels below-right of the anchor (hotspot at top-left of the
        // sprite) is black cursor; far away is white content.
        let atCursor = pixel(pixels, 163, 93, width: 320, height: 180)
        XCTAssertLessThan(atCursor.0, 60)
        let away = pixel(pixels, 40, 40, width: 320, height: 180)
        XCTAssertGreaterThan(away.0, 200)

        // Invisible cursor draws nothing.
        var hidden = cursor
        hidden.visible = false
        let withoutCursor = composer.compose(.init(
            screenImage: white,
            camera: .identity,
            cursor: hidden,
            cursorSprite: blackSprite,
            cursorHotspot: SIMD2(0, 0),
            cursorSpriteSourceSize: SIMD2(8, 8)))
        let cleanPixels = render(withoutCursor, size: output)
        let atCursorClean = pixel(cleanPixels, 163, 93, width: 320, height: 180)
        XCTAssertGreaterThan(atCursorClean.0, 200)
    }

    func testCanvasAspectLetterboxesWithoutCropOrDistortion() {
        // 16:9 source on a 9:16 canvas: the card fits the width, content
        // aspect is preserved, and the bars above/below are background.
        let composer = FrameComposer(
            style: FrameStyle(
                background: .solid(.init(red: 1, green: 0, blue: 0)),
                padding: 0.05, cornerRadius: 0, shadowOpacity: 0, shadowRadius: 0),
            outputSize: SIMD2(180, 320),
            sourceSize: SIMD2(320, 180))
        let geometry = composer.geometry(camera: .identity)
        // Aspect preserved exactly.
        XCTAssertEqual(
            geometry.cardSize.x / geometry.cardSize.y, 320.0 / 180.0, accuracy: 0.001)
        // Fits the padded width, vertically centered.
        XCTAssertEqual(geometry.cardSize.x, 180 - 2 * 0.05 * 180, accuracy: 0.001)
        XCTAssertEqual(
            geometry.cardOrigin.y + geometry.cardSize.y / 2, 160, accuracy: 0.001)

        // Pixels: top bar background, card region content.
        let white = CIImage(color: CIColor(red: 1, green: 1, blue: 1))
            .cropped(to: CGRect(x: 0, y: 0, width: 320, height: 180))
        let pixels = render(
            composer.compose(.init(screenImage: white, camera: .identity)),
            size: SIMD2(180, 320))
        let topBar = pixel(pixels, 90, 20, width: 180, height: 320)
        XCTAssertGreaterThan(topBar.0, 200)  // red background
        XCTAssertLessThan(topBar.1, 50)
        let center = pixel(pixels, 90, 160, width: 180, height: 320)
        XCTAssertGreaterThan(center.1, 200)  // white content
    }

    func testSquareCanvasGeometry() {
        let composer = FrameComposer(
            style: .raw,
            outputSize: SIMD2(400, 400),
            sourceSize: SIMD2(1600, 900))
        let geometry = composer.geometry(camera: .identity)
        XCTAssertEqual(geometry.cardSize.x, 400, accuracy: 0.001)
        XCTAssertEqual(geometry.cardSize.y, 400 * 900 / 1600, accuracy: 0.001)
        XCTAssertEqual(geometry.cardOrigin.y, (400 - geometry.cardSize.y) / 2, accuracy: 0.001)
    }

    func testCompositionIsDeterministic() {
        let output = SIMD2(160.0, 90.0)
        let composer = FrameComposer(
            style: FrameStyle(),
            outputSize: output,
            sourceSize: SIMD2(160, 90))
        let screen = CIImage(color: CIColor(red: 0.4, green: 0.7, blue: 0.2))
            .cropped(to: CGRect(x: 0, y: 0, width: 160, height: 90))
        let camera = CameraState(scale: 1.6, focal: SIMD2(0.4, 0.6))
        let first = render(composer.compose(.init(screenImage: screen, camera: camera)), size: output)
        let second = render(composer.compose(.init(screenImage: screen, camera: camera)), size: output)
        XCTAssertEqual(first, second)
    }
}
