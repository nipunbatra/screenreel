import CoreMedia
import CoreVideo
import XCTest

@testable import CaptureCore
@testable import ProjectModel

/// Collects commits from writer actors for assertions.
actor CommitCollector {
    private(set) var opened: [(path: String, sequence: Int)] = []
    private(set) var committed: [SegmentDescriptor] = []

    func noteOpen(path: String, sequence: Int) { opened.append((path, sequence)) }
    func noteCommit(_ descriptor: SegmentDescriptor) { committed.append(descriptor) }
}

final class SegmentWriterTests: XCTestCase {
    private var directory: URL!
    private var layout: ProjectLayout!

    override func setUp() {
        super.setUp()
        AtomicFile.fullFsync = false
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("aks-writers-\(UUID().uuidString).aks")
        layout = ProjectLayout(root: directory)
        for dir in layout.initialDirectories {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        AtomicFile.fullFsync = true
        super.tearDown()
    }

    // MARK: - Audio

    private func makeAudioWriter(
        collector: CommitCollector, segmentSeconds: Int64 = 2
    ) -> AudioSegmentWriter {
        AudioSegmentWriter(
            trackID: UUID(),
            trackType: .microphone,
            layout: layout,
            sampleRate: 48_000,
            channels: 1,
            segmentDurationNs: segmentSeconds * 1_000_000_000,
            onOpen: { path, sequence in
                await collector.noteOpen(path: path, sequence: sequence)
            },
            onCommit: { descriptor in
                await collector.noteCommit(descriptor)
            })
    }

    private func chunk(startFrame: Int, frames: Int, channels: Int = 1) -> AudioChunk {
        AudioChunk(
            samples: [Float](repeating: 0.2, count: frames * channels),
            frameCount: frames, channels: channels, sampleRate: 48_000,
            ptsNs: Int64(Double(startFrame) / 48_000 * 1_000_000_000))
    }

    func testAudioSegmentsRollAtBoundaryAndVerify() async throws {
        let collector = CommitCollector()
        let writer = makeAudioWriter(collector: collector)
        // 5 seconds of contiguous audio in 1024-frame chunks → 2 rolled
        // segments plus a tail closed by finish().
        var frame = 0
        while frame < 48_000 * 5 {
            let frames = min(1024, 48_000 * 5 - frame)
            try await writer.append(chunk(startFrame: frame, frames: frames))
            frame += frames
        }
        try await writer.finish()

        let committed = await collector.committed
        XCTAssertEqual(committed.count, 3)
        XCTAssertEqual(committed.map(\.sequenceInTrack), [1, 2, 3])
        let totalFrames = committed.compactMap { $0.audio?.sampleCount }.reduce(0, +)
        XCTAssertEqual(totalFrames, 48_000 * 5)
        for descriptor in committed {
            let url = try layout.resolve(relativePath: descriptor.path)
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
            XCTAssertEqual(try Hashing.sha256HexOfFile(at: url), descriptor.sha256)
            XCTAssertNil(descriptor.discontinuityBefore)
            // Segment timing is contiguous.
        }
        for pair in zip(committed, committed.dropFirst()) {
            XCTAssertEqual(pair.0.normalizedEndNs, pair.1.normalizedStartNs)
        }
        // No .partial files remain.
        let leftovers = try FileManager.default
            .contentsOfDirectory(atPath: layout.microphoneDirectory.path)
            .filter { $0.hasSuffix(".partial") }
        XCTAssertTrue(leftovers.isEmpty)
    }

    func testAudioGapClosesSegmentAndMarksDiscontinuity() async throws {
        let collector = CommitCollector()
        let writer = makeAudioWriter(collector: collector, segmentSeconds: 4)
        // Half a second of audio, then a 1-second hole, then more audio.
        try await writer.append(chunk(startFrame: 0, frames: 24_000))
        try await writer.append(chunk(startFrame: 72_000, frames: 24_000))
        try await writer.finish()

        let committed = await collector.committed
        XCTAssertEqual(committed.count, 2)
        XCTAssertNil(committed[0].discontinuityBefore)
        XCTAssertEqual(committed[1].discontinuityBefore, true)
        XCTAssertEqual(committed[0].audio?.sampleCount, 24_000)
        XCTAssertEqual(committed[1].audio?.sampleCount, 24_000)
        // The gap stays a gap: second segment starts at its true time.
        XCTAssertEqual(committed[1].normalizedStartNs, 1_500_000_000)
    }

    func testAudioChannelAdaptation() async throws {
        let collector = CommitCollector()
        let writer = makeAudioWriter(collector: collector)
        // Stereo chunks into a mono track downmix instead of corrupting.
        try await writer.append(chunk(startFrame: 0, frames: 4_800, channels: 2))
        try await writer.finish()
        let committed = await collector.committed
        XCTAssertEqual(committed.first?.audio?.channels, 1)
        XCTAssertEqual(committed.first?.audio?.sampleCount, 4_800)
    }

    // MARK: - Video

    private func makePixelBuffer(width: Int, height: Int, shade: UInt8) -> CVPixelBuffer {
        var bufferOut: CVPixelBuffer?
        CVPixelBufferCreate(
            nil, width, height, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary,
            &bufferOut)
        let buffer = bufferOut!
        CVPixelBufferLockBaseAddress(buffer, [])
        if let base = CVPixelBufferGetBaseAddress(buffer) {
            memset(base, Int32(shade), CVPixelBufferGetBytesPerRow(buffer) * height)
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return buffer
    }

    func testVideoSegmentsRollVerifyAndProbe() async throws {
        let configuration = CaptureConfiguration(
            widthPx: 320, heightPx: 180, nominalFrameRate: 30,
            videoCodec: .hevc, displayID: 1,
            microphoneEnabled: false, segmentDurationSeconds: 2)
        let collector = CommitCollector()
        let writer = VideoSegmentWriter(
            trackID: UUID(),
            settings: .screen(from: configuration),
            layout: layout,
            onOpen: { path, sequence in
                await collector.noteOpen(path: path, sequence: sequence)
            },
            onCommit: { descriptor in
                await collector.noteCommit(descriptor)
            },
            onFault: { kind, message in
                XCTFail("unexpected fault \(kind): \(message)")
            })

        // 5 seconds at 30 fps → segments of 2s/2s/1s.
        for index in 0..<150 {
            let frame = VideoFrame(
                pixelBuffer: makePixelBuffer(width: 320, height: 180, shade: UInt8(index % 250)),
                ptsNs: Int64(index) * 33_333_333)
            try await writer.append(frame)
        }
        try await writer.finish()

        let committed = await collector.committed.sorted { $0.sequenceInTrack < $1.sequenceInTrack }
        XCTAssertEqual(committed.count, 3)
        XCTAssertEqual(committed.compactMap { $0.video?.frameCount }.reduce(0, +), 150)
        let inspector = AVMediaInspector()
        for descriptor in committed {
            let url = try layout.resolve(relativePath: descriptor.path)
            XCTAssertEqual(try Hashing.sha256HexOfFile(at: url), descriptor.sha256)
            let probe = await inspector.probe(url: url, container: .mov)
            XCTAssertTrue(probe.decodable, "\(descriptor.path): \(probe.issues)")
            XCTAssertEqual(probe.video?.frameCount, descriptor.video?.frameCount)
            XCTAssertEqual(probe.video?.widthPx, 320)
        }
        // Commit order matches segment order even with background finalize.
        let commitOrder = await collector.committed.map(\.sequenceInTrack)
        XCTAssertEqual(commitOrder, [1, 2, 3])
    }

    func testVideoExplicitDiscontinuityRotatesSegment() async throws {
        let configuration = CaptureConfiguration(
            widthPx: 160, heightPx: 90, nominalFrameRate: 30,
            videoCodec: .h264, displayID: 1,
            microphoneEnabled: false, segmentDurationSeconds: 4)
        let collector = CommitCollector()
        let writer = VideoSegmentWriter(
            trackID: UUID(), settings: .screen(from: configuration), layout: layout,
            onOpen: { _, _ in },
            onCommit: { descriptor in await collector.noteCommit(descriptor) },
            onFault: { _, _ in })

        for index in 0..<30 {
            try await writer.append(VideoFrame(
                pixelBuffer: makePixelBuffer(width: 160, height: 90, shade: 40),
                ptsNs: Int64(index) * 33_333_333))
        }
        await writer.markDiscontinuity()  // pause/resume path
        for index in 60..<90 {
            try await writer.append(VideoFrame(
                pixelBuffer: makePixelBuffer(width: 160, height: 90, shade: 200),
                ptsNs: Int64(index) * 33_333_333))
        }
        try await writer.finish()

        let committed = await collector.committed.sorted { $0.sequenceInTrack < $1.sequenceInTrack }
        XCTAssertEqual(committed.count, 2)
        XCTAssertNil(committed[0].discontinuityBefore)
        XCTAssertEqual(committed[1].discontinuityBefore, true)
        XCTAssertEqual(committed[1].normalizedStartNs, 60 * 33_333_333)
    }
}

/// Zero-copy append path: frames carrying their original CMSampleBuffer are
/// re-timed onto the session clock and land with the same durable
/// segment/commit semantics as adaptor appends.
extension SegmentWriterTests {
    private func makeSampleBuffer(
        pixelBuffer: CVPixelBuffer, ptsSeconds: Double
    ) throws -> CMSampleBuffer {
        var format: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: nil, imageBuffer: pixelBuffer, formatDescriptionOut: &format)
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: CMTime(seconds: ptsSeconds, preferredTimescale: 1_000_000_000),
            decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        let status = CMSampleBufferCreateReadyWithImageBuffer(
            allocator: nil, imageBuffer: pixelBuffer,
            formatDescription: format!, sampleTiming: &timing,
            sampleBufferOut: &sample)
        XCTAssertEqual(status, noErr)
        return sample!
    }

    func testZeroCopySampleBufferAppendsCommitAndRetime() async throws {
        let configuration = CaptureConfiguration(
            widthPx: 320, heightPx: 180, nominalFrameRate: 30,
            videoCodec: .hevc, displayID: 1,
            microphoneEnabled: false, segmentDurationSeconds: 2)
        let collector = CommitCollector()
        let writer = VideoSegmentWriter(
            trackID: UUID(), settings: .screen(from: configuration), layout: layout,
            onOpen: { _, _ in },
            onCommit: { descriptor in await collector.noteCommit(descriptor) },
            onFault: { _, _ in })

        var pixelBufferOut: CVPixelBuffer?
        CVPixelBufferCreate(
            nil, 320, 180, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            nil, &pixelBufferOut)
        let pixelBuffer = try XCTUnwrap(pixelBufferOut)

        // Source timestamps deliberately offset from session time: the
        // writer must re-time to `ptsNs`, ignoring the buffer's own clock.
        for index in 0..<75 {
            let sessionNs = Int64(index) * 33_333_333
            let sample = try makeSampleBuffer(
                pixelBuffer: pixelBuffer, ptsSeconds: 999 + Double(index) / 30)
            try await writer.append(VideoFrame(
                pixelBuffer: pixelBuffer, ptsNs: sessionNs,
                sourceNs: sessionNs, sampleBuffer: sample))
        }
        try await writer.finish()

        let committed = await collector.committed
        XCTAssertGreaterThanOrEqual(committed.count, 1)
        let total = committed.reduce(0) { $0 + ($1.video?.frameCount ?? 0) }
        XCTAssertEqual(total, 75)
        // Timeline mapping is session-clock based: the first segment starts
        // at 0, not at the buffer's 999 s source time.
        XCTAssertEqual(committed[0].normalizedStartNs, 0)
        XCTAssertLessThan(committed[0].normalizedEndNs, 5_000_000_000)
        for descriptor in committed {
            let url = try XCTUnwrap(try? layout.resolve(relativePath: descriptor.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        }
    }
}
