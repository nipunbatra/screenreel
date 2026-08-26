import CoreImage
import MotionEngine
import TimelineCore
import XCTest

@testable import RenderGraph

/// The ripple ring actually rasterizes: bright at the ring radius, dark at
/// the center and outside, absent when disabled.
final class ClickRippleRenderTests: XCTestCase {

    private let size = SIMD2(320.0, 180.0)

    private func render(_ ripples: [(SIMD2<Double>, Double)]) -> [UInt8] {
        let composer = FrameComposer(style: .raw, outputSize: size, sourceSize: size)
        let black = CIImage(color: CIColor(red: 0, green: 0, blue: 0))
            .cropped(to: CGRect(x: 0, y: 0, width: size.x, height: size.y))
        var input = FrameComposer.Input(screenImage: black, camera: .identity)
        input.clickRipples = ripples.map { (position: $0.0, progress: $0.1) }
        let context = CIContext(options: [
            .workingColorSpace: NSNull(), .outputColorSpace: NSNull(),
        ])
        var pixels = [UInt8](repeating: 0, count: Int(size.x * size.y) * 4)
        context.render(
            composer.compose(input), toBitmap: &pixels, rowBytes: Int(size.x) * 4,
            bounds: CGRect(x: 0, y: 0, width: size.x, height: size.y),
            format: .RGBA8, colorSpace: nil)
        return pixels
    }

    private func luminance(_ pixels: [UInt8], _ x: Int, _ y: Int) -> Int {
        let offset = (y * Int(size.x) + x) * 4
        return Int(pixels[offset])
    }

    func testRingRendersAtExpectedRadius() {
        // Ripple at canvas center, progress 0.5 → radius 16+17 = 33 px.
        let pixels = render([(SIMD2(160, 90), 0.5)])
        // On the ring (33 px right of center).
        XCTAssertGreaterThan(luminance(pixels, 160 + 31, 90), 25,
            "ring should be visible near its radius")
        // The center stays dark (it's a ring, not a disc)…
        XCTAssertLessThan(luminance(pixels, 160, 90), 12)
        // …and so does far outside.
        XCTAssertLessThan(luminance(pixels, 160 + 70, 90), 12)
    }

    func testFadedRippleIsInvisible() {
        let pixels = render([(SIMD2(160, 90), 0.995)])
        XCTAssertLessThan(luminance(pixels, 160 + 49, 90), 12)
    }

    func testNoRipplesRendersNothing() {
        let pixels = render([])
        for x in stride(from: 8, to: 312, by: 24) {
            XCTAssertLessThan(luminance(pixels, x, 90), 8)
        }
    }
}

extension ClickRippleRenderTests {
    /// Shortcut chips rasterize: a dark capsule with bright glyphs appears
    /// bottom-center, and nothing renders when the list is empty or faded.
    func testKeystrokeChipRenders() {
        let composer = FrameComposer(
            style: .raw, outputSize: SIMD2(320, 180), sourceSize: SIMD2(320, 180))
        let grey = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5))
            .cropped(to: CGRect(x: 0, y: 0, width: 320, height: 180))
        var input = FrameComposer.Input(screenImage: grey, camera: .identity)
        input.keystrokeChips = [(text: "⌘C", progress: 0.1)]
        let context = CIContext(options: [
            .workingColorSpace: NSNull(), .outputColorSpace: NSNull(),
        ])
        func pixels(_ image: CIImage) -> [UInt8] {
            var buffer = [UInt8](repeating: 0, count: 320 * 180 * 4)
            context.render(
                image, toBitmap: &buffer, rowBytes: 320 * 4,
                bounds: CGRect(x: 0, y: 0, width: 320, height: 180),
                format: .RGBA8, colorSpace: nil)
            return buffer
        }
        let withChip = pixels(composer.compose(input))
        // The capsule darkens the grey screen near the bottom-center band
        // (CI y-up bottom band = raster rows near the END for our reader…
        // our luminance() indexes top-down, chips sit near y≈180-11-24).
        var sawDark = false
        var sawBright = false
        for y in 130..<176 {
            for x in 120..<200 {
                let offset = (y * 320 + x) * 4
                let value = Int(withChip[offset])
                if value < 80 { sawDark = true }
                if value > 200 { sawBright = true }
            }
        }
        XCTAssertTrue(sawDark, "capsule background missing")
        XCTAssertTrue(sawBright, "glyphs missing")

        // Fully faded chip leaves the frame untouched.
        input.keystrokeChips = [(text: "⌘C", progress: 0.999)]
        let faded = pixels(composer.compose(input))
        var fadedDark = false
        for y in 130..<176 {
            for x in 120..<200 {
                if Int(faded[(y * 320 + x) * 4]) < 80 { fadedDark = true }
            }
        }
        XCTAssertFalse(fadedDark, "faded chip must not render")
    }
}

extension ClickRippleRenderTests {
    /// Rings are clipped to the screen card: a click at the screen edge
    /// must not paint arcs onto the padded wallpaper.
    func testRippleDoesNotBleedOntoWallpaper() {
        let style = FrameStyle(
            background: .solid(.init(red: 0, green: 0, blue: 0)),
            padding: 0.2, cornerRadius: 0.04,
            shadowOpacity: 0, shadowRadius: 0)
        let composer = FrameComposer(
            style: style, outputSize: SIMD2(320, 180), sourceSize: SIMD2(320, 180))
        let dark = CIImage(color: CIColor(red: 0.1, green: 0.1, blue: 0.1))
            .cropped(to: CGRect(x: 0, y: 0, width: 320, height: 180))
        // Click at the source's left edge: the ring would extend well past
        // the card's left boundary if unmasked.
        var input = FrameComposer.Input(screenImage: dark, camera: .identity)
        input.clickRipples = [(position: SIMD2(0, 90), progress: 0.4)]
        let context = CIContext(options: [
            .workingColorSpace: NSNull(), .outputColorSpace: NSNull(),
        ])
        var pixels = [UInt8](repeating: 0, count: 320 * 180 * 4)
        context.render(
            composer.compose(input), toBitmap: &pixels, rowBytes: 320 * 4,
            bounds: CGRect(x: 0, y: 0, width: 320, height: 180),
            format: .RGBA8, colorSpace: nil)
        // Wallpaper (x=2..8, well left of the padded card) stays black.
        for x in 2...8 {
            let offset = (90 * 320 + x) * 4
            XCTAssertLessThan(
                Int(pixels[offset]), 8,
                "ring bled onto the wallpaper at x=\(x)")
        }
    }
}
