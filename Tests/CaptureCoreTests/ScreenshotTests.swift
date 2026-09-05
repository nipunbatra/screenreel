import XCTest
@testable import CaptureCore

final class ScreenshotTests: XCTestCase {
    func testScreenshotKeepsRetinaDimensionsAndExcludesCursor() {
        let settings = SCKCapture.screenshotSettings(.init(widthPx: 4096, heightPx: 2304))
        XCTAssertEqual(settings.width, 4096)
        XCTAssertEqual(settings.height, 2304)
        XCTAssertFalse(settings.showsCursor)
        XCTAssertTrue(settings.ignoreShadowsSingleWindow)
        XCTAssertFalse(settings.capturesAudio)
        XCTAssertFalse(settings.captureMicrophone)
    }

    func testAreaScreenshotCropsInPointsAndOutputsPixels() {
        let settings = SCKCapture.screenshotSettings(.init(widthPx: 1200, heightPx: 800,
            sourceKind: .area, areaRect: .init(x: 80, y: 100, width: 600, height: 400)))
        XCTAssertEqual(settings.sourceRect, CGRect(x: 80, y: 100, width: 600, height: 400))
        XCTAssertEqual(settings.width, 1200)
        XCTAssertEqual(settings.height, 800)
    }
}
