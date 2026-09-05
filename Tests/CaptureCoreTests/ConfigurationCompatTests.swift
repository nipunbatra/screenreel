import Foundation
import XCTest

@testable import CaptureCore

/// Backward compatibility of `CaptureConfiguration`: manifests written
/// before source kinds, camera, and event offsets existed must keep
/// decoding with correct defaults (CLAUDE.md: old projects remain
/// readable).
final class ConfigurationCompatTests: XCTestCase {

    /// The capture JSON exactly as a v1 (pre-source-kinds) build wrote it.
    private let legacyJSON = """
        {
            "widthPx": 4096, "heightPx": 2304, "nominalFrameRate": 30,
            "videoCodec": "hevc", "displayID": 1,
            "microphoneEnabled": true, "systemAudioEnabled": false,
            "audioSampleRate": 48000, "segmentDurationSeconds": 4,
            "bitsPerPixelPerFrame": 0.1
        }
        """

    func testLegacyConfigurationDecodesWithDefaults() throws {
        let decoded = try JSONDecoder().decode(
            CaptureConfiguration.self, from: Data(legacyJSON.utf8))
        XCTAssertEqual(decoded.widthPx, 4096)
        XCTAssertEqual(decoded.sourceKind, .display)
        XCTAssertNil(decoded.windowID)
        XCTAssertNil(decoded.appBundleID)
        XCTAssertNil(decoded.areaRect)
        XCTAssertEqual(decoded.displayScale, 1)
        XCTAssertEqual(decoded.eventOffsetXPx, 0)
        XCTAssertEqual(decoded.eventOffsetYPx, 0)
        XCTAssertFalse(decoded.cameraEnabled)
        XCTAssertNil(decoded.cameraDeviceID)
        XCTAssertFalse(decoded.captureKeystrokesEnabled)
    }

    func testModernConfigurationRoundTrips() throws {
        let original = CaptureConfiguration(
            widthPx: 2560, heightPx: 1440, nominalFrameRate: 60,
            videoCodec: .h264, displayID: 2,
            sourceKind: .area, windowID: nil, appBundleID: nil,
            areaRect: AreaRect(x: 10, y: 20, width: 1280, height: 720),
            displayScale: 2, eventOffsetXPx: 20, eventOffsetYPx: 40,
            microphoneEnabled: false, systemAudioEnabled: true,
            cameraEnabled: true, cameraDeviceID: "uid-1")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(CaptureConfiguration.self, from: data)
        XCTAssertEqual(decoded.sourceKind, .area)
        XCTAssertEqual(decoded.areaRect, original.areaRect)
        XCTAssertEqual(decoded.displayScale, 2)
        XCTAssertEqual(decoded.eventOffsetXPx, 20)
        XCTAssertEqual(decoded.cameraDeviceID, "uid-1")
    }

    func testWindowConfigurationRoundTripsWindowID() throws {
        let original = CaptureConfiguration(
            widthPx: 1600, heightPx: 1000,
            sourceKind: .window, windowID: 99887)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(CaptureConfiguration.self, from: data)
        XCTAssertEqual(decoded.sourceKind, .window)
        XCTAssertEqual(decoded.windowID, 99887)
    }

    func testSourceKindRawValuesAreStable() {
        // Persisted strings are format surface: renaming a case would break
        // old manifests.
        XCTAssertEqual(CaptureSourceKind.display.rawValue, "display")
        XCTAssertEqual(CaptureSourceKind.window.rawValue, "window")
        XCTAssertEqual(CaptureSourceKind.area.rawValue, "area")
        XCTAssertEqual(CaptureSourceKind.application.rawValue, "application")
    }

    func testExplicitKeyboardOptInSurvivesManifestRoundTrip() throws {
        let original = CaptureConfiguration(
            widthPx: 1920, heightPx: 1080, captureKeystrokes: true)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(CaptureConfiguration.self, from: data)
        XCTAssertTrue(decoded.captureKeystrokesEnabled)
    }

    func testGarbageConfigurationFailsCleanly() {
        XCTAssertThrowsError(try JSONDecoder().decode(
            CaptureConfiguration.self, from: Data("{\"widthPx\": true}".utf8)))
    }
}
