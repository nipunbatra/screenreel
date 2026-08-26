import CoreImage
import EventCapture
import Foundation
import ProjectModel
import TimelineCore
import XCTest

@testable import CaptureCore
@testable import PreviewEngine

/// End-to-end coverage for the two new capture dimensions: a recorded camera
/// track composing as PiP through the shared composition path, and
/// area/window event offsets mapping display-local cursor pixels into source
/// pixels.
final class CameraAndOffsetTests: XCTestCase {

    private var root: URL!

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("aks-camoffset-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    func testCameraTrackComposesIntoPreviewFrames() async throws {
        let projectURL = root.appendingPathComponent("cam.aks")
        let durationNs: Int64 = 4_000_000_000
        let configuration = CaptureConfiguration(
            widthPx: 320, heightPx: 180, nominalFrameRate: 30,
            videoCodec: .hevc, displayID: 1,
            microphoneEnabled: false, cameraEnabled: true,
            segmentDurationSeconds: 2)
        let session = CaptureSession(projectURL: projectURL, configuration: configuration)
        try await session.start(
            screen: SyntheticScreenSource(
                width: 320, height: 180, frameRate: 30, durationNs: durationNs),
            microphone: nil, systemAudio: nil,
            camera: SyntheticScreenSource(
                width: 160, height: 90, frameRate: 30, durationNs: durationNs),
            cameraSettings: .camera(
                widthPx: 160, heightPx: 90, frameRate: 30,
                segmentDurationNs: configuration.segmentDurationNs))
        try await Task.sleep(for: .milliseconds(1200))
        _ = try await session.stop()

        let composition = try ProjectComposition(projectURL: projectURL)
        XCTAssertFalse(composition.cameraSegments.isEmpty)

        let time: Int64 = 1_000_000_000
        let visibleFrame = try await composition.frame(at: time)
        let visible = try XCTUnwrap(visibleFrame)
        try composition.updateEdits { $0.camera.hidden = true }
        let hiddenFrame = try await composition.frame(at: time)
        let hidden = try XCTUnwrap(hiddenFrame)

        // The PiP corner region must actually change when the camera hides.
        let context = CIContext(options: [
            .workingColorSpace: NSNull(), .outputColorSpace: NSNull(),
        ])
        func cornerBytes(_ image: CIImage) -> [UInt8] {
            let region = CGRect(
                x: image.extent.width - 80, y: 0, width: 80, height: 60)
            var pixels = [UInt8](repeating: 0, count: 80 * 60 * 4)
            context.render(
                image, toBitmap: &pixels, rowBytes: 80 * 4,
                bounds: region, format: .RGBA8, colorSpace: nil)
            return pixels
        }
        let visibleBytes = cornerBytes(visible)
        let hiddenBytes = cornerBytes(hidden)
        let difference = zip(visibleBytes, hiddenBytes)
            .reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }
        XCTAssertGreaterThan(
            difference, 500,
            "hiding the camera changed nothing — PiP is not rendering")
    }

    func testEventOffsetsShiftCursorEventsIntoSourcePixels() async throws {
        let projectURL = root.appendingPathComponent("area.aks")
        // Area capture: source starts at display pixel (40, 20).
        let configuration = CaptureConfiguration(
            widthPx: 160, heightPx: 90, nominalFrameRate: 30,
            videoCodec: .hevc, displayID: 1,
            sourceKind: .area,
            areaRect: AreaRect(x: 20, y: 10, width: 80, height: 45),
            displayScale: 2,
            eventOffsetXPx: 40,
            eventOffsetYPx: 20,
            microphoneEnabled: false, segmentDurationSeconds: 2)
        let session = CaptureSession(projectURL: projectURL, configuration: configuration)
        try await session.start(
            screen: SyntheticScreenSource(
                width: 160, height: 90, frameRate: 30, durationNs: 2_000_000_000),
            microphone: nil, systemAudio: nil)

        let cursorTrackID = try await session.registerEventTrack(type: .cursorEvents)
        let clickTrackID = try await session.registerEventTrack(type: .clickEvents)
        let store = EventChunkStore(
            layout: session.projectLayout(),
            trackIDs: [.cursor: cursorTrackID, .clicks: clickTrackID],
            onCommit: { [session] chunk in
                try await session.commitEventChunk(chunk)
            })
        // A cursor move at display-local pixel (140, 70): inside the area,
        // which spans display pixels (40,20)–(200,110) at scale 2.
        try await store.append(EventRecord(
            sequence: 1, timeNs: 500_000_000, type: .cursorMove,
            displayID: 1, xPx: 140, yPx: 70))
        try await store.append(EventRecord(
            sequence: 2, timeNs: 900_000_000, type: .cursorMove,
            displayID: 1, xPx: 160, yPx: 80))
        try await store.finish()
        try await Task.sleep(for: .milliseconds(800))
        _ = try await session.stop()

        let composition = try ProjectComposition(projectURL: projectURL)
        // (140, 70) − offset (40, 20) → source pixel (100, 50).
        let position = try XCTUnwrap(
            composition.motionTimeline.targetPosition(at: 600_000_000))
        XCTAssertEqual(position.x, 100, accuracy: 0.001)
        XCTAssertEqual(position.y, 50, accuracy: 0.001)
    }

    func testCaptureConfigurationPersistsSourceFieldsInManifest() async throws {
        let projectURL = root.appendingPathComponent("fields.aks")
        let configuration = CaptureConfiguration(
            widthPx: 160, heightPx: 90, nominalFrameRate: 30,
            videoCodec: .hevc, displayID: 3,
            sourceKind: .window, windowID: 4321,
            displayScale: 2,
            eventOffsetXPx: 12.5, eventOffsetYPx: 7,
            microphoneEnabled: false,
            cameraEnabled: true, cameraDeviceID: "cam-uid",
            segmentDurationSeconds: 2)
        let session = CaptureSession(projectURL: projectURL, configuration: configuration)
        try await session.start(
            screen: SyntheticScreenSource(
                width: 160, height: 90, frameRate: 30, durationNs: 1_000_000_000),
            microphone: nil, systemAudio: nil)
        try await Task.sleep(for: .milliseconds(500))
        _ = try await session.stop()

        let loaded = try ProjectPackage.load(at: projectURL)
        let capture = try XCTUnwrap(loaded.manifest.capture)
        XCTAssertEqual(capture["sourceKind"]?.stringValue, "window")
        XCTAssertEqual(capture["windowID"]?.integerValue, 4321)
        XCTAssertEqual(capture["displayScale"]?.doubleValue, 2)
        XCTAssertEqual(capture["eventOffsetXPx"]?.doubleValue, 12.5)
        XCTAssertEqual(capture["eventOffsetYPx"]?.doubleValue, 7)
        XCTAssertEqual(capture["cameraDeviceID"]?.stringValue, "cam-uid")
    }
}
