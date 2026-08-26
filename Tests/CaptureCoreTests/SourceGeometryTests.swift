import CoreGraphics
import Foundation
import XCTest

@testable import CaptureCore

/// The recorder's source math: capture scale per quality, per-kind pixel
/// dimensions, area clamping, and the event offsets that map display-local
/// cursor pixels into source pixels.
final class SourceGeometryTests: XCTestCase {

    // MARK: Scale

    func testCaptureScaleNativeOnRetina() {
        XCTAssertEqual(
            SourceGeometry.captureScale(nativeWidthPx: 4096, widthPoints: 2048, native: true),
            2.0)
    }

    func testCaptureScaleStandardIsAlwaysOne() {
        XCTAssertEqual(
            SourceGeometry.captureScale(nativeWidthPx: 4096, widthPoints: 2048, native: false),
            1.0)
    }

    func testCaptureScaleSurvivesZeroPoints() {
        // A degenerate display report must not divide by zero.
        let scale = SourceGeometry.captureScale(nativeWidthPx: 4096, widthPoints: 0, native: true)
        XCTAssertTrue(scale.isFinite)
    }

    func testEvenPixelsRoundsDownAndClampsUp() {
        XCTAssertEqual(SourceGeometry.evenPixels(1281), 1280)
        XCTAssertEqual(SourceGeometry.evenPixels(1280), 1280)
        XCTAssertEqual(SourceGeometry.evenPixels(0), 2)
        XCTAssertEqual(SourceGeometry.evenPixels(-5), 2)
    }

    // MARK: Display

    func testDisplayNativeDimensions() {
        let resolved = SourceGeometry.display(widthPoints: 2048, heightPoints: 1152, scale: 2)
        XCTAssertEqual(resolved.widthPx, 4096)
        XCTAssertEqual(resolved.heightPx, 2304)
        XCTAssertEqual(resolved.eventOffsetXPx, 0)
        XCTAssertEqual(resolved.eventOffsetYPx, 0)
        XCTAssertNil(resolved.areaRect)
    }

    func testDisplayStandardHalvesRetina() {
        let resolved = SourceGeometry.display(widthPoints: 2048, heightPoints: 1152, scale: 1)
        XCTAssertEqual(resolved.widthPx, 2048)
        XCTAssertEqual(resolved.heightPx, 1152)
    }

    // MARK: Area

    func testAreaInsideDisplayKeepsRequestedRect() {
        let resolved = SourceGeometry.area(
            requested: AreaRect(x: 100, y: 50, width: 1280, height: 720),
            displayWidthPoints: 2048, displayHeightPoints: 1152, scale: 2)
        XCTAssertEqual(resolved.areaRect, AreaRect(x: 100, y: 50, width: 1280, height: 720))
        XCTAssertEqual(resolved.widthPx, 2560)
        XCTAssertEqual(resolved.heightPx, 1440)
        XCTAssertEqual(resolved.eventOffsetXPx, 200)
        XCTAssertEqual(resolved.eventOffsetYPx, 100)
    }

    func testAreaClampsToDisplayEdges() {
        let resolved = SourceGeometry.area(
            requested: AreaRect(x: 2000, y: 1100, width: 1280, height: 720),
            displayWidthPoints: 2048, displayHeightPoints: 1152, scale: 2)
        let rect = try! XCTUnwrap(resolved.areaRect)
        XCTAssertLessThanOrEqual(rect.x + rect.width, 2048)
        XCTAssertLessThanOrEqual(rect.y + rect.height, 1152)
        XCTAssertGreaterThanOrEqual(rect.width, 16)
        XCTAssertGreaterThanOrEqual(rect.height, 16)
    }

    func testAreaNegativeOriginClampsToZero() {
        let resolved = SourceGeometry.area(
            requested: AreaRect(x: -50, y: -20, width: 800, height: 600),
            displayWidthPoints: 2048, displayHeightPoints: 1152, scale: 1)
        let rect = try! XCTUnwrap(resolved.areaRect)
        XCTAssertEqual(rect.x, 0)
        XCTAssertEqual(rect.y, 0)
        XCTAssertEqual(resolved.eventOffsetXPx, 0)
    }

    func testAreaTinyRequestGetsMinimumSize() {
        let resolved = SourceGeometry.area(
            requested: AreaRect(x: 10, y: 10, width: 1, height: 1),
            displayWidthPoints: 2048, displayHeightPoints: 1152, scale: 2)
        let rect = try! XCTUnwrap(resolved.areaRect)
        XCTAssertGreaterThanOrEqual(rect.width, 16)
        XCTAssertGreaterThanOrEqual(rect.height, 16)
        XCTAssertGreaterThanOrEqual(resolved.widthPx, 32)
    }

    // MARK: Window

    func testWindowOffsetsAreDisplayRelative() {
        let resolved = SourceGeometry.window(
            frame: CGRect(x: 300, y: 200, width: 1000, height: 700),
            displayBounds: CGRect(x: 0, y: 0, width: 2048, height: 1152),
            scale: 2)
        XCTAssertEqual(resolved.widthPx, 2000)
        XCTAssertEqual(resolved.heightPx, 1400)
        XCTAssertEqual(resolved.eventOffsetXPx, 600)
        XCTAssertEqual(resolved.eventOffsetYPx, 400)
    }

    func testWindowOnSecondaryDisplaySubtractsDisplayOrigin() {
        // Display arranged to the right of the main one: global points start
        // at x=2048.
        let resolved = SourceGeometry.window(
            frame: CGRect(x: 2148, y: 60, width: 800, height: 600),
            displayBounds: CGRect(x: 2048, y: 0, width: 1920, height: 1080),
            scale: 1)
        XCTAssertEqual(resolved.eventOffsetXPx, 100)
        XCTAssertEqual(resolved.eventOffsetYPx, 60)
    }

    // MARK: Application + presets

    func testApplicationUsesFullDisplayCanvas() {
        let app = SourceGeometry.application(widthPoints: 1920, heightPoints: 1080, scale: 2)
        let display = SourceGeometry.display(widthPoints: 1920, heightPoints: 1080, scale: 2)
        XCTAssertEqual(app, display)
    }

    func testCenteredAreaIsCenteredAndClamped() {
        let rect = SourceGeometry.centeredArea(
            width: 1280, height: 720, displayWidthPoints: 2048, displayHeightPoints: 1152)
        XCTAssertEqual(rect.x, (2048 - 1280) / 2)
        XCTAssertEqual(rect.y, (1152 - 720) / 2)

        let oversized = SourceGeometry.centeredArea(
            width: 9000, height: 9000, displayWidthPoints: 2048, displayHeightPoints: 1152)
        XCTAssertEqual(oversized.width, 2048)
        XCTAssertEqual(oversized.height, 1152)
        XCTAssertEqual(oversized.x, 0)
    }
}
