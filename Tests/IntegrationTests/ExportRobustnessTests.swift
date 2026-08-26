import AVFoundation
import XCTest

@testable import CaptureCore
@testable import ExportEngine
@testable import ProjectModel

final class ExportRobustnessTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        super.setUp()
        AtomicFile.fullFsync = false
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("aks-export-robustness-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        AtomicFile.fullFsync = true
        super.tearDown()
    }

    func testExportExactlyOneVideoSegmentWithoutAudio() async throws {
        let projectURL = try await makeProject(
            name: "single-video", videoDurationNs: 4_000_000_000,
            audioStartNs: nil, audioDurationNs: nil)
        let loaded = try ProjectPackage.load(at: projectURL)
        let committedVideo = loaded.journal.records(ofType: .segmentCommitted).compactMap {
            try? $0.payload.decoded(as: SegmentDescriptor.self)
        }.filter { $0.trackType == .screen }
        XCTAssertEqual(committedVideo.count, 1)
        XCTAssertFalse(loaded.manifest.tracks.contains { $0.type == .microphone })

        let outputURL = directory.appendingPathComponent("single-video.mp4")
        let result = try await SegmentAssembler.assemble(projectAt: projectURL, to: outputURL)
        XCTAssertEqual(result.videoSegments, 1)
        XCTAssertEqual(result.videoFrames, 4)
        XCTAssertEqual(result.audioFrames, 0)
        XCTAssertTrue(result.warnings.contains { $0.contains("no committed audio") })

        let asset = AVURLAsset(url: outputURL)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(videoTracks.count, 1)
        XCTAssertTrue(audioTracks.isEmpty)
    }

    func testExportInsertsSilenceBeforeMicrophoneStartsTwoSecondsLate() async throws {
        guard supportsAACEncoding() else {
            throw XCTSkip("AVFoundation AAC encoder is unavailable in this test environment")
        }
        let projectURL = try await makeProject(
            name: "leading-gap", videoDurationNs: 4_000_000_000,
            audioStartNs: 2_000_000_000, audioDurationNs: 2_000_000_000)
        let outputURL = directory.appendingPathComponent("leading-gap.mp4")

        let result = try await SegmentAssembler.assemble(projectAt: projectURL, to: outputURL)
        XCTAssertGreaterThanOrEqual(result.silenceFramesInserted, 95_900)
        XCTAssertLessThanOrEqual(result.silenceFramesInserted, 96_100)

        let leadingRMS = try await audioRMS(of: outputURL, startSeconds: 0.25, durationSeconds: 1)
        let recordedRMS = try await audioRMS(of: outputURL, startSeconds: 2.5, durationSeconds: 1)
        XCTAssertLessThan(leadingRMS, 0.005, "leading gap contains non-silent samples")
        XCTAssertGreaterThan(recordedRMS, 0.05, "recorded microphone range is silent")
    }

    func testCancellationRemovesPartialAndPreservesExistingDestination() async throws {
        let projectURL = try await makeProject(
            name: "cancel", videoDurationNs: 12_000_000_000,
            audioStartNs: 0, audioDurationNs: 12_000_000_000)
        let outputURL = directory.appendingPathComponent("cancelled.mp4")
        let originalDestination = Data("pre-existing destination".utf8)
        try originalDestination.write(to: outputURL)
        let partialURL = outputURL.deletingLastPathComponent()
            .appendingPathComponent(outputURL.lastPathComponent + ".partial.mp4")

        let gate = ExportCancellationGate()
        let exportTask = Task {
            try await SegmentAssembler.assemble(
                projectAt: projectURL,
                to: outputURL,
                options: .init(
                    includeAudio: false,
                    overwrite: true,
                    progress: { stage, fraction in gate.progress(stage: stage, fraction: fraction) }))
        }
        let waitTask = Task.detached { gate.waitUntilReached(timeout: 5) }
        let reached = await waitTask.value
        XCTAssertTrue(reached, "export never reached the deterministic cancellation gate")

        exportTask.cancel()
        gate.release()
        do {
            _ = try await exportTask.value
            XCTFail("cancelled export unexpectedly completed")
        } catch {
            XCTAssertTrue(error is CancellationError, "expected CancellationError, got \(error)")
        }

        XCTAssertEqual(try Data(contentsOf: outputURL), originalDestination)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: partialURL.path),
            "cancelled export left \(partialURL.lastPathComponent)")
    }

    // MARK: - Fixtures

    private func supportsAACEncoding() -> Bool {
        let probeURL = directory.appendingPathComponent("aac-capability-probe.mp4")
        defer { try? FileManager.default.removeItem(at: probeURL) }
        guard let writer = try? AVAssetWriter(outputURL: probeURL, fileType: .mp4) else {
            return false
        }
        return writer.canApply(outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000.0,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 160_000,
        ], forMediaType: .audio)
    }

    private func makeProject(
        name: String,
        videoDurationNs: Int64,
        audioStartNs: Int64?,
        audioDurationNs: Int64?
    ) async throws -> URL {
        let projectURL = directory.appendingPathComponent("\(name).aks")
        let created = try await ProjectPackage.create(
            at: projectURL,
            clock: ClockAnchor(
                originContinuousTicks: 1, originAbsoluteTicks: 1,
                timebaseNumer: 1, timebaseDenom: 1,
                originWallTime: "2026-08-24T00:00:00.000Z"))
        let layout = created.layout
        let journal = created.journal
        let store = created.manifestStore

        let screenTrack = TrackDescriptor(type: .screen, displayID: 1, cursorBaked: false)
        try await journal.append(
            type: .trackStarted, timeNs: 0,
            payload: JournalPayload.trackStarted(screenTrack), durable: false)
        _ = try await store.save { $0.tracks.append(screenTrack) }

        let segmentDurationNs: Int64 = 4_000_000_000
        let videoSegmentCount = max(1, Int((videoDurationNs + segmentDurationNs - 1) / segmentDurationNs))
        let fixture = try XCTUnwrap(Data(
            base64Encoded: Self.h264FixtureBase64,
            options: .ignoreUnknownCharacters))
        for index in 0..<videoSegmentCount {
            let sequence = index + 1
            let fileURL = layout.screenDirectory.appendingPathComponent(
                ProjectLayout.segmentFileName(type: .screen, displayID: 1, sequence: sequence))
            try fixture.write(to: fileURL)
            let startNs = Int64(index) * segmentDurationNs
            let endNs = min(videoDurationNs, startNs + segmentDurationNs)
            let descriptor = SegmentDescriptor(
                trackID: screenTrack.id, trackType: .screen,
                path: layout.relativePath(of: fileURL), sequenceInTrack: sequence,
                container: .mov, codec: .h264,
                video: VideoFormatInfo(
                    widthPx: 64, heightPx: 64, nominalFrameRate: 1, frameCount: 4),
                sourceStartNs: startNs, sourceEndNs: endNs,
                normalizedStartNs: startNs, normalizedEndNs: endNs,
                byteSize: Int64(fixture.count), sha256: Hashing.sha256Hex(fixture),
                commitSequence: 0)
            let record = try await journal.append(
                type: .segmentCommitted, timeNs: endNs, durable: false
            ) { sequence in
                var committed = descriptor
                committed.commitSequence = sequence
                return try JournalPayload.segmentCommitted(committed)
            }
            let committed = try record.payload.decoded(as: SegmentDescriptor.self)
            _ = try await store.save { $0.appendSegment(committed) }
        }

        if let audioStartNs, let audioDurationNs {
            let micTrack = TrackDescriptor(type: .microphone, deviceName: "Offset Test Mic")
            try await journal.append(
                type: .trackStarted, timeNs: audioStartNs,
                payload: JournalPayload.trackStarted(micTrack), durable: false)
            _ = try await store.save { $0.tracks.append(micTrack) }

            let sampleRate = 48_000.0
            let sampleCount = Int(Double(audioDurationNs) / 1_000_000_000 * sampleRate)
            let fileURL = layout.microphoneDirectory.appendingPathComponent("mic-000001.caf")
            let caf = try CAFWriter(url: fileURL, sampleRate: sampleRate, channels: 1)
            try caf.append(samples: [Float](repeating: 0.25, count: sampleCount))
            try caf.close()
            let bytes = try Data(contentsOf: fileURL)
            let descriptor = SegmentDescriptor(
                trackID: micTrack.id, trackType: .microphone,
                path: layout.relativePath(of: fileURL), sequenceInTrack: 1,
                container: .caf, codec: .pcmFloat32,
                audio: AudioFormatInfo(
                    sampleRate: sampleRate, channels: 1,
                    bitsPerSample: 32, floatingPoint: true, sampleCount: sampleCount),
                sourceStartNs: audioStartNs, sourceEndNs: audioStartNs + audioDurationNs,
                normalizedStartNs: audioStartNs, normalizedEndNs: audioStartNs + audioDurationNs,
                byteSize: Int64(bytes.count), sha256: Hashing.sha256Hex(bytes),
                commitSequence: 0)
            let record = try await journal.append(
                type: .segmentCommitted,
                timeNs: audioStartNs + audioDurationNs,
                durable: false
            ) { sequence in
                var committed = descriptor
                committed.commitSequence = sequence
                return try JournalPayload.segmentCommitted(committed)
            }
            let committed = try record.payload.decoded(as: SegmentDescriptor.self)
            _ = try await store.save { $0.appendSegment(committed) }
        }

        try await journal.append(
            type: .sessionStopped, timeNs: videoDurationNs,
            payload: JournalPayload.empty(), durable: false)
        try await journal.append(
            type: .validationCompleted, timeNs: videoDurationNs,
            payload: JournalPayload.empty(), durable: false)
        try await journal.append(
            type: .sessionFinalized, timeNs: videoDurationNs,
            payload: JournalPayload.empty(), durable: false)
        try await journal.synchronize()
        _ = try await store.save { $0.state = .ready }
        try? FileManager.default.removeItem(at: layout.sessionLockURL)
        return projectURL
    }

    /// Four one-frame-per-second H.264 samples in a 64×64 QuickTime file.
    /// Embedded so export robustness tests do not depend on a hardware encoder.
    private static let h264FixtureBase64 = """
    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
    """

    private func audioRMS(
        of url: URL, startSeconds: Double, durationSeconds: Double
    ) async throws -> Double {
        let asset = AVURLAsset(url: url)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let track = try XCTUnwrap(audioTracks.first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
        ])
        reader.add(output)
        reader.timeRange = CMTimeRange(
            start: CMTime(seconds: startSeconds, preferredTimescale: 48_000),
            duration: CMTime(seconds: durationSeconds, preferredTimescale: 48_000))
        guard reader.startReading() else { return 0 }

        var sumSquares = 0.0
        var count = 0
        while let sample = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            var length = 0
            var pointer: UnsafeMutablePointer<CChar>?
            CMBlockBufferGetDataPointer(
                block, atOffset: 0, lengthAtOffsetOut: nil,
                totalLengthOut: &length, dataPointerOut: &pointer)
            guard let pointer else { continue }
            pointer.withMemoryRebound(to: Float.self, capacity: length / 4) { floats in
                for index in 0..<(length / 4) {
                    sumSquares += Double(floats[index] * floats[index])
                    count += 1
                }
            }
        }
        return count == 0 ? 0 : (sumSquares / Double(count)).squareRoot()
    }
}

private final class ExportCancellationGate: @unchecked Sendable {
    private let reached = DispatchSemaphore(value: 0)
    private let resume = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var didReach = false

    func progress(stage: String, fraction: Double) {
        guard stage == "video", fraction == 0 else { return }
        lock.lock()
        let shouldBlock = !didReach
        if shouldBlock { didReach = true }
        lock.unlock()
        guard shouldBlock else { return }
        reached.signal()
        _ = resume.wait(timeout: .now() + 5)
    }

    func waitUntilReached(timeout: TimeInterval) -> Bool {
        reached.wait(timeout: .now() + timeout) == .success
    }

    func release() {
        resume.signal()
    }
}
