import AVFoundation
import XCTest

@testable import CaptureCore
@testable import ProjectModel

/// A/V sync matrix:
/// drive the REAL `CaptureSession` + segment writers with synthetic sources
/// across sample rates × channel counts × frame rates × delivery pathologies,
/// then decode every finalized segment with AVFoundation and assert
///   (a) the muxed video PTS span matches the sent span within 150 ms,
///   (b) decoded audio duration is within 150 ms of the generated duration,
///   (c) per-track start offsets are within one video frame duration.
/// The tolerance is deliberately loose: the bug class this guards against
/// (stretched or collapsed timelines) produces errors of a second or more.
///
/// Set AKS_SYNC_REPORT=/path/to/report.json to write a JSON report of every
/// executed case.
final class SyncMatrixTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("aks-syncmatrix-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    // MARK: - Case description

    private enum Pathology: String {
        case steady, jitter, drops, gap
    }

    private struct MatrixCase {
        var name: String
        var sampleRate: Double
        var channels: Int
        var fps: Double
        var pathology: Pathology

        /// Content span in ns: gap cases span 5 s (with a 2 s hole), all
        /// others 3 s — every case ≤ 5 s of content.
        var contentNs: Int64 {
            pathology == .gap ? 5_000_000_000 : 3_000_000_000
        }

        /// Uniform ~60 fps generation demand, the pacing this pipeline is
        /// gated to sustain with zero drops (see SyntheticSessionTests).
        var pace: Double {
            switch fps {
            case ..<20: return 4
            case ..<40: return 2
            default: return 1
            }
        }

        /// Video PTS jitter stays under half the frame spacing so the stream
        /// remains strictly monotonic (the writer's skip policy is tested
        /// elsewhere); ±15 ms at 30 fps per the matrix spec.
        var videoJitterNs: Int64 { fps >= 40 ? 7_000_000 : 15_000_000 }

        /// Audio chunk jitter stays under the audio writer's 20 ms gap
        /// tolerance relative to the first chunk (|j_k − j_0| ≤ 18 ms), so
        /// jitter is absorbed rather than declared a discontinuity.
        var audioJitterNs: Int64 { 9_000_000 }

        var delivery: (video: SyntheticDelivery, audio: SyntheticDelivery) {
            switch pathology {
            case .steady:
                return (.steady, .steady)
            case .jitter:
                return (
                    SyntheticDelivery(jitterAmplitudeNs: videoJitterNs, jitterSeed: 0xA5),
                    SyntheticDelivery(jitterAmplitudeNs: audioJitterNs, jitterSeed: 0x5A)
                )
            case .drops:
                // Every 7th video frame never delivered; audio steady.
                return (SyntheticDelivery(dropEveryNth: 7), .steady)
            case .gap:
                // A 2 s delivery hole mid-stream on both tracks (a stall /
                // system-sleep shaped pathology).
                let gap = SyntheticDelivery(gapStartNs: 1_500_000_000, gapDurationNs: 2_000_000_000)
                return (gap, gap)
            }
        }
    }

    // MARK: - Runner

    /// A machine-load hiccup that overflows the bounded handoff invalidates
    /// the sent-vs-muxed premise (frames legitimately never reached the
    /// writers), so one clean retry is allowed; two consecutive lossy runs
    /// on a ≤5 s window fail the case.
    private func run(_ matrixCase: MatrixCase) async throws {
        let first = try await capture(matrixCase, attempt: 1)
        if first.summary.droppedBuffers == 0, first.summary.droppedVideoFrames == 0 {
            try await verify(matrixCase, outcome: first)
            return
        }
        print("\(matrixCase.name): delivery loss under load "
            + "(\(first.summary.droppedBuffers) buffers, "
            + "\(first.summary.droppedVideoFrames) frames) — retrying once")
        let second = try await capture(matrixCase, attempt: 2)
        XCTAssertEqual(second.summary.droppedBuffers, 0, "\(matrixCase.name): handoff overflow twice")
        XCTAssertEqual(second.summary.droppedVideoFrames, 0, "\(matrixCase.name): writer drops twice")
        try await verify(matrixCase, outcome: second)
    }

    private struct CaseOutcome {
        var projectURL: URL
        var summary: CaptureSession.StopSummary
        var videoSent: SyntheticSentStats
        var audioSent: SyntheticSentStats
    }

    private func capture(_ matrixCase: MatrixCase, attempt: Int) async throws -> CaseOutcome {
        let projectURL = directory.appendingPathComponent("\(matrixCase.name)-\(attempt).aks")
        let stereo = matrixCase.channels == 2
        // The mic writer is mono and the system-audio writer is stereo by
        // design, so channel count selects which real audio path is driven.
        let configuration = CaptureConfiguration(
            widthPx: 320, heightPx: 180,
            nominalFrameRate: matrixCase.fps,
            videoCodec: .hevc, displayID: 1,
            microphoneEnabled: !stereo,
            microphoneDeviceName: stereo ? nil : "Synthetic Microphone",
            systemAudioEnabled: stereo,
            audioSampleRate: matrixCase.sampleRate,
            segmentDurationSeconds: 4)
        let session = CaptureSession(projectURL: projectURL, configuration: configuration)
        let (videoDelivery, audioDelivery) = matrixCase.delivery
        let screen = SyntheticScreenSource(
            width: 320, height: 180, frameRate: matrixCase.fps,
            durationNs: matrixCase.contentNs, pace: matrixCase.pace,
            delivery: videoDelivery)
        let audio = SyntheticAudioSource(
            sampleRate: matrixCase.sampleRate, channels: matrixCase.channels,
            durationNs: matrixCase.contentNs, pace: matrixCase.pace,
            delivery: audioDelivery)

        try await session.start(
            screen: screen,
            microphone: stereo ? nil : audio,
            systemAudio: stereo ? audio : nil)
        await screen.waitUntilFinished()
        await audio.waitUntilFinished()
        let summary = try await session.stop()
        return CaseOutcome(
            projectURL: projectURL,
            summary: summary,
            videoSent: screen.sentStats(),
            audioSent: audio.sentStats())
    }

    private func verify(_ matrixCase: MatrixCase, outcome: CaseOutcome) async throws {
        let summary = outcome.summary
        let videoSent = outcome.videoSent
        let audioSent = outcome.audioSent
        let stereo = matrixCase.channels == 2
        let frameDurationNs = Int64(1_000_000_000 / matrixCase.fps)
        let toleranceNs: Int64 = 150_000_000

        XCTAssertTrue(
            summary.validation.isHealthy,
            "\(matrixCase.name): \(summary.validation.issues)")

        // Decode the finalized segments.
        let loaded = try ProjectPackage.load(at: outcome.projectURL)
        let audioType: TrackType = stereo ? .systemAudio : .microphone
        let videoSegments = segments(of: .screen, in: loaded)
        let audioSegments = segments(of: audioType, in: loaded)
        XCTAssertFalse(videoSegments.isEmpty, "\(matrixCase.name): no video segments")
        XCTAssertFalse(audioSegments.isEmpty, "\(matrixCase.name): no audio segments")

        // (a) muxed video span vs sent span.
        let (muxedPts, muxedSampleCount) = try await absoluteVideoSamplePtsNs(
            segments: videoSegments, layout: loaded.layout)
        XCTAssertEqual(
            muxedSampleCount, videoSent.frames,
            "\(matrixCase.name): muxed frame count != sent frame count")
        let sentSpanNs = (videoSent.lastPtsNs ?? 0) - (videoSent.firstPtsNs ?? 0)
        let muxedSpanNs = (muxedPts.last ?? 0) - (muxedPts.first ?? 0)
        XCTAssertLessThanOrEqual(
            abs(muxedSpanNs - sentSpanNs), toleranceNs,
            "\(matrixCase.name): muxed video span \(ms(muxedSpanNs)) ms "
                + "vs sent \(ms(sentSpanNs)) ms")

        // (b) decoded audio duration vs generated duration.
        var decodedAudioFrames: Int64 = 0
        for segment in audioSegments {
            let url = try loaded.layout.resolve(relativePath: segment.path)
            let file = try AVAudioFile(forReading: url)
            XCTAssertEqual(
                file.processingFormat.sampleRate, matrixCase.sampleRate,
                "\(matrixCase.name): \(segment.path) decoded at wrong rate")
            XCTAssertEqual(
                Int(file.processingFormat.channelCount), matrixCase.channels,
                "\(matrixCase.name): \(segment.path) decoded wrong channel count")
            decodedAudioFrames += file.length
        }
        let decodedAudioNs = Int64(
            Double(decodedAudioFrames) / matrixCase.sampleRate * 1_000_000_000)
        let generatedAudioNs = Int64(
            Double(audioSent.frames) / matrixCase.sampleRate * 1_000_000_000)
        XCTAssertLessThanOrEqual(
            abs(decodedAudioNs - generatedAudioNs), toleranceNs,
            "\(matrixCase.name): decoded audio \(ms(decodedAudioNs)) ms "
                + "vs generated \(ms(generatedAudioNs)) ms")

        // (c) per-track start offsets within one video frame duration.
        let videoStartNs = videoSegments.first?.normalizedStartNs ?? 0
        let audioStartNs = audioSegments.first?.normalizedStartNs ?? 0
        XCTAssertLessThanOrEqual(
            abs(videoStartNs - audioStartNs), frameDurationNs,
            "\(matrixCase.name): track starts diverge — video \(ms(videoStartNs)) ms, "
                + "audio \(ms(audioStartNs)) ms")

        SyncMatrixReport.shared.record([
            "name": .string(matrixCase.name),
            "sampleRate": .double(matrixCase.sampleRate),
            "channels": .integer(Int64(matrixCase.channels)),
            "fps": .double(matrixCase.fps),
            "pathology": .string(matrixCase.pathology.rawValue),
            "sentVideoFrames": .integer(Int64(videoSent.frames)),
            "muxedVideoFrames": .integer(Int64(muxedSampleCount)),
            "sentVideoSpanMs": .double(ms(sentSpanNs)),
            "muxedVideoSpanMs": .double(ms(muxedSpanNs)),
            "videoSpanDeltaMs": .double(ms(muxedSpanNs - sentSpanNs)),
            "generatedAudioMs": .double(ms(generatedAudioNs)),
            "decodedAudioMs": .double(ms(decodedAudioNs)),
            "audioDeltaMs": .double(ms(decodedAudioNs - generatedAudioNs)),
            "trackStartOffsetMs": .double(ms(videoStartNs - audioStartNs)),
            "videoSegments": .integer(Int64(videoSegments.count)),
            "audioSegments": .integer(Int64(audioSegments.count)),
        ])
    }

    private func ms(_ ns: Int64) -> Double {
        (Double(ns) / 1e6 * 1000).rounded() / 1000
    }

    private func segments(
        of type: TrackType, in loaded: ProjectPackage.Loaded
    ) -> [SegmentDescriptor] {
        (loaded.manifest.tracks.first { $0.type == type }?.segments ?? [])
            .sorted { $0.sequenceInTrack < $1.sequenceInTrack }
    }

    /// Every video sample's PTS on the session timeline, reconstructed the
    /// same way the exporter does: container-relative PTS re-anchored at the
    /// segment's committed `normalizedStartNs`. `sampleCount` sums the real
    /// samples (a passthrough reader may coalesce several into one buffer).
    private func absoluteVideoSamplePtsNs(
        segments: [SegmentDescriptor], layout: ProjectLayout
    ) async throws -> (pts: [Int64], sampleCount: Int) {
        var all: [Int64] = []
        var sampleCount = 0
        for segment in segments {
            let url = try layout.resolve(relativePath: segment.path)
            let asset = AVURLAsset(
                url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
            let tracks = try await asset.loadTracks(withMediaType: .video)
            guard let track = tracks.first else {
                XCTFail("\(segment.path): no video track")
                continue
            }
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            output.alwaysCopiesSampleData = false
            reader.add(output)
            XCTAssertTrue(reader.startReading(), "\(segment.path): reader failed")
            var containerPts: [Int64] = []
            while let sample = output.copyNextSampleBuffer() {
                // Passthrough reading ends with zero-sample "empty media"
                // marker buffers whose PTS sits one frame past the stream;
                // only real samples count.
                let samples = CMSampleBufferGetNumSamples(sample)
                guard samples > 0 else { continue }
                sampleCount += samples
                let pts = CMSampleBufferGetPresentationTimeStamp(sample)
                guard pts.isNumeric else { continue }
                containerPts.append(Int64((pts.seconds * 1e9).rounded()))
            }
            XCTAssertNotEqual(reader.status, .failed, "\(segment.path): read failed")
            containerPts.sort()
            guard let first = containerPts.first else { continue }
            all.append(contentsOf: containerPts.map { $0 - first + segment.normalizedStartNs })
        }
        return (all.sorted(), sampleCount)
    }

    // MARK: - Curated 14-case sweep

    // Rate × channel grid at a steady 30 fps (6 cases).
    func testSteady44k1Mono30() async throws {
        try await run(.init(name: "44k1-mono-30-steady", sampleRate: 44_100, channels: 1, fps: 30, pathology: .steady))
    }

    func testSteady44k1Stereo30() async throws {
        try await run(.init(name: "44k1-stereo-30-steady", sampleRate: 44_100, channels: 2, fps: 30, pathology: .steady))
    }

    func testSteady48kMono30() async throws {
        try await run(.init(name: "48k-mono-30-steady", sampleRate: 48_000, channels: 1, fps: 30, pathology: .steady))
    }

    func testSteady48kStereo30() async throws {
        try await run(.init(name: "48k-stereo-30-steady", sampleRate: 48_000, channels: 2, fps: 30, pathology: .steady))
    }

    func testSteady96kMono30() async throws {
        try await run(.init(name: "96k-mono-30-steady", sampleRate: 96_000, channels: 1, fps: 30, pathology: .steady))
    }

    func testSteady96kStereo30() async throws {
        try await run(.init(name: "96k-stereo-30-steady", sampleRate: 96_000, channels: 2, fps: 30, pathology: .steady))
    }

    // Frame-rate spread at 48 k mono (2 cases).
    func testSteady48kMono15fps() async throws {
        try await run(.init(name: "48k-mono-15-steady", sampleRate: 48_000, channels: 1, fps: 15, pathology: .steady))
    }

    func testSteady48kMono60fps() async throws {
        try await run(.init(name: "48k-mono-60-steady", sampleRate: 48_000, channels: 1, fps: 60, pathology: .steady))
    }

    // Delivery pathologies at the 48 k/mono/30 baseline (3 cases).
    func testJitter48kMono30() async throws {
        try await run(.init(name: "48k-mono-30-jitter", sampleRate: 48_000, channels: 1, fps: 30, pathology: .jitter))
    }

    func testDrops48kMono30() async throws {
        try await run(.init(name: "48k-mono-30-drops", sampleRate: 48_000, channels: 1, fps: 30, pathology: .drops))
    }

    func testGap48kMono30() async throws {
        try await run(.init(name: "48k-mono-30-gap", sampleRate: 48_000, channels: 1, fps: 30, pathology: .gap))
    }

    // Cross combinations (3 cases).
    func testJitter44k1Stereo60() async throws {
        try await run(.init(name: "44k1-stereo-60-jitter", sampleRate: 44_100, channels: 2, fps: 60, pathology: .jitter))
    }

    func testGap96kMono15() async throws {
        try await run(.init(name: "96k-mono-15-gap", sampleRate: 96_000, channels: 1, fps: 15, pathology: .gap))
    }

    func testDrops48kStereo30() async throws {
        try await run(.init(name: "48k-stereo-30-drops", sampleRate: 48_000, channels: 2, fps: 30, pathology: .drops))
    }
}

/// Accumulates per-case results across the suite and rewrites the JSON report
/// at the `AKS_SYNC_REPORT` path after every case, so the file is complete
/// for whatever subset of cases actually ran.
final class SyncMatrixReport: @unchecked Sendable {
    static let shared = SyncMatrixReport()
    private let lock = NSLock()
    private var cases: [JSONValue] = []

    func record(_ fields: [String: JSONValue]) {
        guard let path = ProcessInfo.processInfo.environment["AKS_SYNC_REPORT"],
            !path.isEmpty
        else { return }
        lock.lock()
        defer { lock.unlock() }
        cases.append(.object(fields))
        let report = JSONValue.object([
            "suite": .string("SyncMatrixTests"),
            "generatedAt": .string(RFC3339.now()),
            "cases": .array(cases),
        ])
        if let text = try? report.canonicalString() {
            try? Data(text.utf8).write(to: URL(fileURLWithPath: path))
        }
    }
}
