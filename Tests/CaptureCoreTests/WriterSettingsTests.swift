import XCTest

@testable import CaptureCore

/// VideoWriterSettings: the screen builder mirrors the capture
/// configuration exactly, and the camera builder carries the higher
/// bits-per-pixel that moving camera content needs.
final class WriterSettingsTests: XCTestCase {

    func testScreenSettingsMirrorConfiguration() {
        let configuration = CaptureConfiguration(
            widthPx: 3840, heightPx: 2160, nominalFrameRate: 60,
            videoCodec: .h264, displayID: 7,
            segmentDurationSeconds: 3, bitsPerPixelPerFrame: 0.15)
        let settings = VideoWriterSettings.screen(from: configuration)
        XCTAssertEqual(settings.trackType, .screen)
        XCTAssertEqual(settings.displayID, 7)
        XCTAssertEqual(settings.widthPx, 3840)
        XCTAssertEqual(settings.heightPx, 2160)
        XCTAssertEqual(settings.nominalFrameRate, 60)
        XCTAssertEqual(settings.codec, .h264)
        XCTAssertEqual(settings.bitsPerPixelPerFrame, 0.15)
        XCTAssertEqual(settings.segmentDurationNs, 3_000_000_000)
    }

    func testCameraSettingsUseCameraTrackAndRicherBitrate() {
        let settings = VideoWriterSettings.camera(
            widthPx: 1920, heightPx: 1080, frameRate: 30,
            segmentDurationNs: 4_000_000_000)
        XCTAssertEqual(settings.trackType, .camera)
        XCTAssertNil(settings.displayID)
        XCTAssertEqual(settings.codec, .hevc)
        // Camera content moves everywhere; it must not inherit the
        // screen-content bitrate.
        XCTAssertGreaterThan(settings.bitsPerPixelPerFrame, 0.1)
    }

    func testSegmentDurationClampStaysInAcceptedRange() {
        let short = CaptureConfiguration(
            widthPx: 100, heightPx: 100, segmentDurationSeconds: 0.5)
        XCTAssertEqual(short.segmentDurationNs, 2_000_000_000)
        let long = CaptureConfiguration(
            widthPx: 100, heightPx: 100, segmentDurationSeconds: 60)
        XCTAssertEqual(long.segmentDurationNs, 5_000_000_000)
    }

    func testScreenSettingsForStandardQualityDimensions() {
        // A 1× capture flows through untouched (no double scaling).
        let configuration = CaptureConfiguration(
            widthPx: 2048, heightPx: 1152, displayScale: 1)
        let settings = VideoWriterSettings.screen(from: configuration)
        XCTAssertEqual(settings.widthPx, 2048)
        XCTAssertEqual(settings.heightPx, 1152)
    }
}
