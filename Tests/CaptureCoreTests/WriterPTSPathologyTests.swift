import CoreMedia
import CoreVideo
import Foundation
import ProjectModel
import XCTest

@testable import CaptureCore

/// Adapted from Cap's PTS-pathology suites:
/// hostile timestamp patterns through the real segment writer must never
/// produce overlapping packets, dropped-forever pipelines, or timeline
/// spans that disagree with what was actually sent.
final class WriterPTSPathologyTests: XCTestCase {

    private var root: URL!
    private var layout: ProjectLayout!

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("screenreel-ptspath-\(UUID().uuidString)")
        layout = ProjectLayout(root: root.appendingPathComponent("p.screenreel"))
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
        func add(_ d: SegmentDescriptor) { descriptors.append(d) }
    }

    private func runPattern(_ ptsSequence: [Int64]) async throws -> [SegmentDescriptor] {
        let configuration = CaptureConfiguration(
            widthPx: 160, heightPx: 90, nominalFrameRate: 30,
            videoCodec: .hevc, displayID: 1,
            microphoneEnabled: false, segmentDurationSeconds: 2)
        let collector = Collector()
        let writer = VideoSegmentWriter(
            trackID: UUID(), settings: .screen(from: configuration), layout: layout,
            onOpen: { _, _ in },
            onCommit: { d in await collector.add(d) },
            onFault: { _, _ in })
        var out: CVPixelBuffer?
        CVPixelBufferCreate(nil, 160, 90, kCVPixelFormatType_32BGRA, nil, &out)
        let buffer = try XCTUnwrap(out)
        for pts in ptsSequence {
            try await writer.append(VideoFrame(pixelBuffer: buffer, ptsNs: pts))
        }
        try await writer.finish()
        return await collector.descriptors.sorted { $0.sequenceInTrack < $1.sequenceInTrack }
    }

    /// Committed segments never overlap and stay ordered, whatever came in.
    private func assertNoOverlaps(
        _ segments: [SegmentDescriptor], file: StaticString = #filePath, line: UInt = #line
    ) {
        for (a, b) in zip(segments, segments.dropFirst()) {
            XCTAssertLessThanOrEqual(
                a.normalizedEndNs, b.normalizedStartNs,
                "segments overlap: \(a.sequenceInTrack)/\(b.sequenceInTrack)",
                file: file, line: line)
        }
        for segment in segments {
            XCTAssertLessThan(
                segment.normalizedStartNs, segment.normalizedEndNs,
                file: file, line: line)
        }
    }

    func testSawtoothTimestampsKeepMonotonicOutput() async throws {
        // Forward 3, back 1 — repeatedly. Only strictly-advancing frames
        // may land.
        var pts: [Int64] = []
        var t: Int64 = 0
        for cycle in 0..<40 {
            _ = cycle
            t += 33_333_333
            pts.append(t)
            t += 33_333_333
            pts.append(t)
            pts.append(t - 20_000_000)  // regression
        }
        let segments = try await runPattern(pts)
        assertNoOverlaps(segments)
        let frames = segments.reduce(0) { $0 + ($1.video?.frameCount ?? 0) }
        XCTAssertEqual(frames, 80)  // regressions all skipped
    }

    func testMicrosecondDuplicatesCollapse() async throws {
        // Same-microsecond duplicates (SCK repeats around reconfigures).
        var pts: [Int64] = []
        for index in 0..<60 {
            let t = Int64(index) * 33_333_333
            pts.append(t)
            if index % 7 == 0 { pts.append(t) }
        }
        let segments = try await runPattern(pts)
        assertNoOverlaps(segments)
        let frames = segments.reduce(0) { $0 + ($1.video?.frameCount ?? 0) }
        XCTAssertEqual(frames, 60)
    }

    func testBurstAfterLongGapSpansCorrectly() async throws {
        // 1 s of frames, 10 s of nothing, then a 60-frame burst: the
        // timeline span must equal what was sent, no discontinuity flags,
        // and every file must decode.
        var pts: [Int64] = (0..<30).map { Int64($0) * 33_333_333 }
        let resume: Int64 = 11_000_000_000
        pts += (0..<60).map { resume + Int64($0) * 33_333_333 }
        let segments = try await runPattern(pts)
        assertNoOverlaps(segments)
        XCTAssertEqual(segments.first?.normalizedStartNs, 0)
        let lastEnd = try XCTUnwrap(segments.last?.normalizedEndNs)
        let expectedEnd = resume + 60 * 33_333_333
        XCTAssertEqual(Double(lastEnd), Double(expectedEnd), accuracy: 40_000_000)
        XCTAssertTrue(segments.allSatisfy { $0.discontinuityBefore == nil })
        for segment in segments {
            let url = try XCTUnwrap(try? layout.resolve(relativePath: segment.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
            XCTAssertGreaterThan(segment.byteSize, 0)
        }
    }

    func testHostilePauseResumeCycles() async throws {
        // Cap-map gap #5 (reduced): repeated pause/resume through the real
        // session — one discontinuity per cycle, strictly ordered segments
        // on BOTH video tracks.
        let projectURL = root.appendingPathComponent("cycles.screenreel")
        let configuration = CaptureConfiguration(
            widthPx: 160, heightPx: 90, nominalFrameRate: 30,
            videoCodec: .hevc, displayID: 1,
            microphoneEnabled: false, cameraEnabled: true,
            segmentDurationSeconds: 2)
        let session = CaptureSession(projectURL: projectURL, configuration: configuration)
        try await session.start(
            screen: SyntheticScreenSource(
                width: 160, height: 90, frameRate: 30,
                durationNs: 6_000_000_000, pace: 1),
            microphone: nil, systemAudio: nil,
            camera: SyntheticScreenSource(
                width: 160, height: 90, frameRate: 30,
                durationNs: 6_000_000_000, pace: 1),
            cameraSettings: .camera(
                widthPx: 0, heightPx: 0, frameRate: 30,
                segmentDurationNs: configuration.segmentDurationNs))
        for _ in 0..<3 {
            try await Task.sleep(for: .milliseconds(500))
            try await session.pause()
            try await Task.sleep(for: .milliseconds(200))
            try await session.resume()
        }
        try await Task.sleep(for: .milliseconds(700))
        _ = try await session.stop()

        let loaded = try ProjectPackage.load(at: projectURL)
        let segments = loaded.journal.records
            .filter { $0.type == .segmentCommitted }
            .compactMap { try? $0.payload.decoded(as: SegmentDescriptor.self) }
        for type in [TrackType.screen, .camera] {
            let track = segments.filter { $0.trackType == type }
                .sorted { $0.sequenceInTrack < $1.sequenceInTrack }
            assertNoOverlaps(track)
            let flagged = track.filter { $0.discontinuityBefore == true }.count
            XCTAssertEqual(flagged, 3, "\(type): one discontinuity per resume")
        }
    }
}

extension WriterPTSPathologyTests {
    /// Cap-map §3: our skip-don't-bump policy must be AUDITABLE — every
    /// skipped frame lands in a committed descriptor's droppedFrames, so
    /// totals are never silent.
    func testSkippedFramesAreAccountedInDescriptors() async throws {
        let configuration = CaptureConfiguration(
            widthPx: 160, heightPx: 90, nominalFrameRate: 30,
            videoCodec: .hevc, displayID: 1,
            microphoneEnabled: false, segmentDurationSeconds: 2)
        let collector = Collector()
        let writer = VideoSegmentWriter(
            trackID: UUID(), settings: .screen(from: configuration), layout: layout,
            onOpen: { _, _ in },
            onCommit: { d in await collector.add(d) },
            onFault: { _, _ in })
        var out: CVPixelBuffer?
        CVPixelBufferCreate(nil, 160, 90, kCVPixelFormatType_32BGRA, nil, &out)
        let buffer = try XCTUnwrap(out)
        var duplicates = 0
        for index in 0..<90 {
            let pts = Int64(index) * 33_333_333
            try await writer.append(VideoFrame(pixelBuffer: buffer, ptsNs: pts))
            if index % 10 == 0 {
                duplicates += 1
                try await writer.append(VideoFrame(pixelBuffer: buffer, ptsNs: pts))
            }
        }
        try await writer.finish()
        let segments = await collector.descriptors
        let accounted = segments.reduce(0) { $0 + ($1.droppedFrames ?? 0) }
        let total = await writer.droppedFrames
        XCTAssertEqual(total, duplicates)
        XCTAssertEqual(accounted, duplicates,
            "every skipped frame must appear in a committed descriptor")
    }
}
