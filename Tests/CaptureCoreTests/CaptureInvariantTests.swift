import CoreMedia
import CoreVideo
import Foundation
import ProjectModel
import XCTest

@testable import CaptureCore

/// Timing-discipline invariants adapted from studying Cap's test practice
///: non-advancing timestamps never kill a
/// recording, pauses mark discontinuities on EVERY video track, sparse
/// content (VFR gaps) is legal, and audio/video start close together.
final class CaptureInvariantTests: XCTestCase {

    private var root: URL!
    private var layout: ProjectLayout!

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("aks-invariants-\(UUID().uuidString)")
        let projectURL = root.appendingPathComponent("p.aks")
        layout = ProjectLayout(root: projectURL)
        for directory in layout.initialDirectories {
            try? FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
        }
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    private actor Collector {
        var descriptors: [SegmentDescriptor] = []
        func add(_ descriptor: SegmentDescriptor) { descriptors.append(descriptor) }
    }

    private func makeWriter(
        collector: Collector, segmentSeconds: Double = 2
    ) -> VideoSegmentWriter {
        let configuration = CaptureConfiguration(
            widthPx: 160, heightPx: 90, nominalFrameRate: 30,
            videoCodec: .hevc, displayID: 1,
            microphoneEnabled: false, segmentDurationSeconds: segmentSeconds)
        return VideoSegmentWriter(
            trackID: UUID(), settings: .screen(from: configuration), layout: layout,
            onOpen: { _, _ in },
            onCommit: { descriptor in await collector.add(descriptor) },
            onFault: { _, _ in })
    }

    private func makeBuffer() throws -> CVPixelBuffer {
        var out: CVPixelBuffer?
        CVPixelBufferCreate(nil, 160, 90, kCVPixelFormatType_32BGRA, nil, &out)
        return try XCTUnwrap(out)
    }

    // MARK: Non-advancing timestamps

    func testDuplicateTimestampIsSkippedNotFatal() async throws {
        let collector = Collector()
        let writer = makeWriter(collector: collector)
        let buffer = try makeBuffer()
        for index in 0..<30 {
            let pts = Int64(index) * 33_333_333
            try await writer.append(VideoFrame(pixelBuffer: buffer, ptsNs: pts))
            if index == 10 {
                // The repeat MUST NOT throw (it used to fail the
                // AVAssetWriter append and end the recording).
                try await writer.append(VideoFrame(pixelBuffer: buffer, ptsNs: pts))
            }
        }
        try await writer.finish()
        let committed = await collector.descriptors
        let frames = committed.reduce(0) { $0 + ($1.video?.frameCount ?? 0) }
        XCTAssertEqual(frames, 30)
        let dropped = await writer.droppedFrames
        XCTAssertEqual(dropped, 1)
    }

    func testBackwardsTimestampIsSkippedNotFatal() async throws {
        let collector = Collector()
        let writer = makeWriter(collector: collector)
        let buffer = try makeBuffer()
        try await writer.append(VideoFrame(pixelBuffer: buffer, ptsNs: 1_000_000_000))
        try await writer.append(VideoFrame(pixelBuffer: buffer, ptsNs: 900_000_000))
        try await writer.append(VideoFrame(pixelBuffer: buffer, ptsNs: 1_033_333_333))
        try await writer.finish()
        let committed = await collector.descriptors
        let frames = committed.reduce(0) { $0 + ($1.video?.frameCount ?? 0) }
        XCTAssertEqual(frames, 2)
    }

    // MARK: Sparse content (VFR)

    func testLongFrameGapIsLegalAndKeepsTimeline() async throws {
        // A static screen delivers no frames for seconds; the recording
        // must span the gap without discontinuity flags or pts damage.
        let collector = Collector()
        let writer = makeWriter(collector: collector, segmentSeconds: 2)
        let buffer = try makeBuffer()
        try await writer.append(VideoFrame(pixelBuffer: buffer, ptsNs: 0))
        try await writer.append(VideoFrame(pixelBuffer: buffer, ptsNs: 33_333_333))
        // 6-second hole (three segment durations).
        try await writer.append(VideoFrame(pixelBuffer: buffer, ptsNs: 6_000_000_000))
        try await writer.append(VideoFrame(pixelBuffer: buffer, ptsNs: 6_033_333_333))
        try await writer.finish()
        let committed = await collector.descriptors.sorted {
            $0.sequenceInTrack < $1.sequenceInTrack
        }
        XCTAssertEqual(committed.count, 2)
        XCTAssertNil(committed[0].discontinuityBefore)
        XCTAssertNil(committed[1].discontinuityBefore)
        XCTAssertEqual(committed[1].normalizedStartNs, 6_000_000_000)
    }

    // MARK: Pause / resume

    func testPauseMarksDiscontinuityOnScreenAndCameraTracks() async throws {
        let projectURL = root.appendingPathComponent("pause.aks")
        let configuration = CaptureConfiguration(
            widthPx: 160, heightPx: 90, nominalFrameRate: 30,
            videoCodec: .hevc, displayID: 1,
            microphoneEnabled: false, cameraEnabled: true,
            segmentDurationSeconds: 2)
        let session = CaptureSession(projectURL: projectURL, configuration: configuration)
        let screen = SyntheticScreenSource(
            width: 160, height: 90, frameRate: 30, durationNs: 2_000_000_000, pace: 1)
        let camera = SyntheticScreenSource(
            width: 160, height: 90, frameRate: 30, durationNs: 2_000_000_000, pace: 1)
        try await session.start(
            screen: screen, microphone: nil, systemAudio: nil,
            camera: camera,
            cameraSettings: .camera(
                widthPx: 160, heightPx: 90, frameRate: 30,
                segmentDurationNs: configuration.segmentDurationNs))
        try await Task.sleep(for: .milliseconds(700))
        try await session.pause()
        try await Task.sleep(for: .milliseconds(300))
        try await session.resume()
        try await Task.sleep(for: .milliseconds(1500))
        _ = try await session.stop()

        let loaded = try ProjectPackage.load(at: projectURL)
        let segments = loaded.journal.records
            .filter { $0.type == .segmentCommitted }
            .compactMap { try? $0.payload.decoded(as: SegmentDescriptor.self) }
        let screenFlagged = segments.filter {
            $0.trackType == .screen && $0.discontinuityBefore == true
        }
        let cameraFlagged = segments.filter {
            $0.trackType == .camera && $0.discontinuityBefore == true
        }
        // The fix under test: BOTH video tracks flag the resume point.
        XCTAssertEqual(screenFlagged.count, 1, "screen segments: \(segments.filter { $0.trackType == .screen }.count)")
        XCTAssertEqual(cameraFlagged.count, 1, "camera segments: \(segments.filter { $0.trackType == .camera }.count)")
    }

    // MARK: A/V start alignment

    func testAudioAndVideoStartWithinTolerance() async throws {
        let projectURL = root.appendingPathComponent("sync.aks")
        let configuration = CaptureConfiguration(
            widthPx: 160, heightPx: 90, nominalFrameRate: 30,
            videoCodec: .hevc, displayID: 1,
            microphoneEnabled: true, segmentDurationSeconds: 2)
        let session = CaptureSession(projectURL: projectURL, configuration: configuration)
        try await session.start(
            screen: SyntheticScreenSource(
                width: 160, height: 90, frameRate: 30, durationNs: 2_000_000_000),
            microphone: SyntheticAudioSource(
                channels: 1, durationNs: 2_000_000_000),
            systemAudio: nil)
        try await Task.sleep(for: .milliseconds(900))
        _ = try await session.stop()

        let loaded = try ProjectPackage.load(at: projectURL)
        let segments = loaded.journal.records
            .filter { $0.type == .segmentCommitted }
            .compactMap { try? $0.payload.decoded(as: SegmentDescriptor.self) }
        let videoStart = segments.filter { $0.trackType == .screen }
            .map(\.normalizedStartNs).min()
        let audioStart = segments.filter { $0.trackType == .microphone }
            .map(\.normalizedStartNs).min()
        let video = try XCTUnwrap(videoStart)
        let audio = try XCTUnwrap(audioStart)
        // Same session clock, synthetic sources fire together: the tracks
        // must begin within 150 ms of each other.
        XCTAssertLessThan(abs(video - audio), 150_000_000)
    }
}
