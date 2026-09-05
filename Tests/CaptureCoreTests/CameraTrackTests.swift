import Foundation
import ProjectModel
import XCTest

@testable import CaptureCore

/// The camera track rides the same segmented, journaled pipeline as the
/// screen: raw segments under `raw/camera/`, committed descriptors typed
/// `.camera`, and a healthy validation afterwards.
final class CameraTrackTests: XCTestCase {

    func testCameraTrackRecordsSegmentsAlongsideScreen() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("screenreel-camera-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let projectURL = root.appendingPathComponent("cam.screenreel")

        let durationNs: Int64 = 5_000_000_000
        let configuration = CaptureConfiguration(
            widthPx: 320, heightPx: 180, nominalFrameRate: 30,
            videoCodec: .hevc, displayID: 1,
            microphoneEnabled: false,
            cameraEnabled: true,
            segmentDurationSeconds: 2)
        let session = CaptureSession(projectURL: projectURL, configuration: configuration)
        let screen = SyntheticScreenSource(
            width: 320, height: 180, frameRate: 30, durationNs: durationNs)
        let camera = SyntheticScreenSource(
            width: 160, height: 90, frameRate: 30, durationNs: durationNs)
        try await session.start(
            screen: screen, microphone: nil, systemAudio: nil,
            camera: camera,
            cameraSettings: .camera(
                widthPx: 160, heightPx: 90, frameRate: 30,
                segmentDurationNs: configuration.segmentDurationNs))

        // Synthetic sources at pace 0 deliver everything promptly; give the
        // pipeline a moment, then stop.
        try await Task.sleep(for: .milliseconds(1500))
        let summary = try await session.stop()

        XCTAssertGreaterThan(summary.videoFrames, 0)
        XCTAssertGreaterThan(summary.cameraFrames, 0)
        XCTAssertTrue(summary.validation.isHealthy,
            "validation issues: \(summary.validation.issues)")

        // Committed camera descriptors carry the camera track type, land
        // under raw/camera/, and reflect the camera's own dimensions.
        let loaded = try ProjectPackage.load(at: projectURL)
        let cameraTracks = loaded.manifest.tracks.filter { $0.type == .camera }
        XCTAssertEqual(cameraTracks.count, 1)
        let cameraSegments = loaded.journal.records
            .filter { $0.type == .segmentCommitted }
            .compactMap { try? $0.payload.decoded(as: SegmentDescriptor.self) }
            .filter { $0.trackType == .camera }
        XCTAssertFalse(cameraSegments.isEmpty)
        for segment in cameraSegments {
            XCTAssertTrue(segment.path.hasPrefix("raw/camera/"),
                "unexpected camera segment path \(segment.path)")
            XCTAssertEqual(segment.video?.widthPx, 160)
            XCTAssertEqual(segment.video?.heightPx, 90)
            let url = try XCTUnwrap(try? loaded.layout.resolve(relativePath: segment.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        }

        // Screen segments are untouched by the camera's presence.
        let screenSegments = loaded.journal.records
            .filter { $0.type == .segmentCommitted }
            .compactMap { try? $0.payload.decoded(as: SegmentDescriptor.self) }
            .filter { $0.trackType == .screen }
        XCTAssertFalse(screenSegments.isEmpty)
        for segment in screenSegments {
            XCTAssertEqual(segment.video?.widthPx, 320)
        }
    }

    func testSessionWithoutCameraHasNoCameraTrack() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("screenreel-nocam-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let projectURL = root.appendingPathComponent("plain.screenreel")

        let configuration = CaptureConfiguration(
            widthPx: 160, heightPx: 90, nominalFrameRate: 30,
            videoCodec: .hevc, displayID: 1,
            microphoneEnabled: false, segmentDurationSeconds: 2)
        let session = CaptureSession(projectURL: projectURL, configuration: configuration)
        let screen = SyntheticScreenSource(
            width: 160, height: 90, frameRate: 30, durationNs: 2_000_000_000)
        try await session.start(screen: screen, microphone: nil, systemAudio: nil)
        try await Task.sleep(for: .milliseconds(800))
        let summary = try await session.stop()

        XCTAssertEqual(summary.cameraFrames, 0)
        let loaded = try ProjectPackage.load(at: projectURL)
        XCTAssertTrue(loaded.manifest.tracks.allSatisfy { $0.type != .camera })
    }
}
