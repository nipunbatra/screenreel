import CoreGraphics
import XCTest

@testable import AppSupport

/// The area picker's math: drag normalization, clamping, moving, the
/// AppKit (bottom-left) → capture (top-left) flip, and strip placement.
final class AreaGeometryTests: XCTestCase {

    private let screen = CGRect(x: 0, y: 0, width: 1728, height: 1117)

    // MARK: Drag normalization

    func testDragInAnyDirectionYieldsTheSameRect() {
        let a = CGPoint(x: 100, y: 200)
        let b = CGPoint(x: 400, y: 500)
        let expected = CGRect(x: 100, y: 200, width: 300, height: 300)
        XCTAssertEqual(AreaGeometry.selection(from: a, to: b, within: screen), expected)
        XCTAssertEqual(AreaGeometry.selection(from: b, to: a, within: screen), expected)
        XCTAssertEqual(
            AreaGeometry.selection(
                from: CGPoint(x: 400, y: 200), to: CGPoint(x: 100, y: 500), within: screen),
            expected)
    }

    func testDragPastTheScreenEdgeIsClamped() {
        let rect = AreaGeometry.selection(
            from: CGPoint(x: 1500, y: 1000), to: CGPoint(x: 2000, y: 1400), within: screen)
        XCTAssertEqual(rect, CGRect(x: 1500, y: 1000, width: 228, height: 117))
    }

    func testDragBelowMinimumIsAStrayClick() {
        XCTAssertNil(
            AreaGeometry.selection(
                from: CGPoint(x: 10, y: 10), to: CGPoint(x: 20, y: 300), within: screen))
        XCTAssertNil(
            AreaGeometry.selection(
                from: CGPoint(x: 10, y: 10), to: CGPoint(x: 10, y: 10), within: screen))
    }

    func testSelectionSnapsToWholePoints() {
        let rect = AreaGeometry.selection(
            from: CGPoint(x: 10.4, y: 10.6), to: CGPoint(x: 110.5, y: 210.2), within: screen)
        XCTAssertEqual(rect, CGRect(x: 10, y: 11, width: 100, height: 200))
    }

    // MARK: Moving

    func testMoveStaysInsideBounds() {
        let sel = CGRect(x: 100, y: 100, width: 300, height: 200)
        XCTAssertEqual(
            AreaGeometry.moved(sel, by: CGSize(width: 50, height: -30), within: screen),
            CGRect(x: 150, y: 70, width: 300, height: 200))
        // Shoved way off the top-right: pinned at the corner, size intact.
        XCTAssertEqual(
            AreaGeometry.moved(sel, by: CGSize(width: 5000, height: 5000), within: screen),
            CGRect(x: 1728 - 300, y: 1117 - 200, width: 300, height: 200))
        XCTAssertEqual(
            AreaGeometry.moved(sel, by: CGSize(width: -5000, height: -5000), within: screen),
            CGRect(x: 0, y: 0, width: 300, height: 200))
    }

    // MARK: Coordinate flip

    func testBottomLeftToTopLeftFlipMatchesSourceGeometryConvention() {
        // A 300×200 selection whose bottom edge sits 100 pt above the
        // bottom of a 1117 pt tall display starts 817 pt below its top.
        let local = CGRect(x: 100, y: 100, width: 300, height: 200)
        let flipped = AreaGeometry.displayLocalTopLeft(local, screenHeight: 1117)
        XCTAssertEqual(flipped, CGRect(x: 100, y: 817, width: 300, height: 200))
        // A selection touching the top of the display has y = 0.
        let top = CGRect(x: 0, y: 1117 - 200, width: 300, height: 200)
        XCTAssertEqual(
            AreaGeometry.displayLocalTopLeft(top, screenHeight: 1117).minY, 0)
    }

    func testFlipRoundTrips() {
        let local = CGRect(x: 37, y: 512, width: 640, height: 360)
        let back = AreaGeometry.screenLocalBottomLeft(
            AreaGeometry.displayLocalTopLeft(local, screenHeight: 1117), screenHeight: 1117)
        XCTAssertEqual(back, local)
    }

    func testSecondaryDisplayUsesItsOwnOriginNotThePrimarys() {
        // A display to the left of and above the primary: AppKit frame
        // origin (-2560, 200). A window covering it reports view points
        // relative to its own bottom-left, but anything measured in global
        // coordinates must subtract the frame origin first.
        let secondary = CGRect(x: -2560, y: 200, width: 2560, height: 1440)
        let global = CGRect(x: -2560 + 100, y: 200 + 300, width: 800, height: 600)
        let local = AreaGeometry.screenLocal(global, screenFrame: secondary)
        XCTAssertEqual(local, CGRect(x: 100, y: 300, width: 800, height: 600))
        let capture = AreaGeometry.displayLocalTopLeft(local, screenHeight: secondary.height)
        XCTAssertEqual(capture, CGRect(x: 100, y: 1440 - 900, width: 800, height: 600))
    }

    // MARK: Control strip

    func testStripSitsCenteredBelowTheSelection() {
        let sel = CGRect(x: 400, y: 400, width: 400, height: 300)
        let origin = AreaGeometry.stripOrigin(
            for: sel, stripSize: CGSize(width: 200, height: 40), within: screen)
        XCTAssertEqual(origin, CGPoint(x: 500, y: 400 - 10 - 40))
    }

    func testStripFlipsAboveWhenNoRoomBelow() {
        let sel = CGRect(x: 400, y: 0, width: 400, height: 300)
        let origin = AreaGeometry.stripOrigin(
            for: sel, stripSize: CGSize(width: 200, height: 40), within: screen)
        XCTAssertEqual(origin, CGPoint(x: 500, y: 310))
    }

    func testStripTucksInsideAFullScreenSelection() {
        let origin = AreaGeometry.stripOrigin(
            for: screen, stripSize: CGSize(width: 200, height: 40), within: screen)
        XCTAssertEqual(origin.y, 10)
        XCTAssertGreaterThanOrEqual(origin.x, 10)
    }

    func testStripNeverLeavesTheScreenHorizontally() {
        let sel = CGRect(x: 1700, y: 500, width: 28, height: 200)
        let origin = AreaGeometry.stripOrigin(
            for: sel, stripSize: CGSize(width: 200, height: 40), within: screen)
        XCTAssertEqual(origin.x, 1728 - 200 - 10)
    }

    func testSizeLabel() {
        XCTAssertEqual(
            AreaGeometry.sizeLabel(for: CGRect(x: 0, y: 0, width: 1280, height: 720)),
            "1280 × 720")
    }
}
