import AVFoundation
import XCTest

@testable import CaptureCore
@testable import ExportEngine
@testable import ProjectModel

final class ExportTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("screenreel-export-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    /// Record a synthetic session and return its project URL.
    private func makeProject(
        durationNs: Int64,
        micSilenceAfterNs: Int64? = nil,
        pace: Double = 4
    ) async throws -> URL {
        let projectURL = directory.appendingPathComponent("p-\(UUID().uuidString).screenreel")
        let configuration = CaptureConfiguration(
            widthPx: 320, heightPx: 180, nominalFrameRate: 30,
            videoCodec: .hevc, displayID: 1,
            microphoneEnabled: true, microphoneDeviceName: "Synthetic Microphone",
            segmentDurationSeconds: 4)
        let session = CaptureSession(projectURL: projectURL, configuration: configuration)
        let screen = SyntheticScreenSource(
            width: 320, height: 180, frameRate: 30, durationNs: durationNs, pace: pace)
        let mic = SyntheticAudioSource(
            channels: 1, durationNs: durationNs, pace: pace,
            silenceAfterNs: micSilenceAfterNs)
        try await session.start(screen: screen, microphone: mic, systemAudio: nil)
        await screen.waitUntilFinished()
        await mic.waitUntilFinished()
        _ = try await session.stop()
        return projectURL
    }

    func testExportProducesValidatedMP4WithAudio() async throws {
        let durationNs: Int64 = 12_000_000_000
        let projectURL = try await makeProject(durationNs: durationNs)
        let outputURL = directory.appendingPathComponent("out.mp4")

        let result = try await SegmentAssembler.assemble(projectAt: projectURL, to: outputURL)

        // Compare against what capture actually committed: on a loaded
        // machine the paced synthetic source may drop a few frames at the
        // handoff (counted), and the export's contract is "everything
        // committed", not a nominal frame count.
        let committed: Int = try ProjectPackage.load(at: projectURL).journal.records
            .filter { $0.type == .segmentCommitted }
            .compactMap { try? $0.payload.decoded(as: SegmentDescriptor.self) }
            .filter { $0.trackType == .screen }
            .reduce(into: 0) { $0 += ($1.video?.frameCount ?? 0) }
        XCTAssertEqual(Int(result.videoFrames), committed)
        XCTAssertGreaterThan(result.videoFrames, 340)
        XCTAssertEqual(result.videoSegments, 3)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outputURL.path))
        XCTAssertTrue(result.warnings.isEmpty, "\(result.warnings)")

        // Independent verification with AVFoundation, per the contract:
        // never trust the exporter's own accounting alone.
        let asset = AVURLAsset(url: outputURL)
        let duration = try await asset.load(.duration)
        XCTAssertEqual(duration.seconds, 12.0, accuracy: 0.25)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(videoTracks.count, 1)
        XCTAssertEqual(audioTracks.count, 1)
        // Stream copy must preserve the codec.
        let formats = try await videoTracks[0].load(.formatDescriptions)
        XCTAssertEqual(formats.first.map { CMFormatDescriptionGetMediaSubType($0) }, kCMVideoCodecType_HEVC)

        // The audio is genuinely non-silent (AUDIO_PIPELINE §8: near-zero
        // energy output is a failure, not success).
        let rms = try await Self.audioRMS(of: outputURL, seconds: 2)
        XCTAssertGreaterThan(rms, 0.05, "exported audio is silent")

        // Raw assets untouched: the project still validates deeply.
        let report = await Validator(options: .init(
            verifyChecksums: true, mediaInspector: AVMediaInspector()))
            .validate(projectAt: projectURL)
        XCTAssertTrue(report.isHealthy, "\(report.issues)")
    }

    func testExportInsertsSilenceForMicGap() async throws {
        // Mic dies 4 s into a 10 s recording: the export still spans the full
        // video duration, with silence covering the missing tail.
        let projectURL = try await makeProject(
            durationNs: 10_000_000_000, micSilenceAfterNs: 4_000_000_000)
        let outputURL = directory.appendingPathComponent("gap.mp4")
        let result = try await SegmentAssembler.assemble(projectAt: projectURL, to: outputURL)

        XCTAssertGreaterThan(result.silenceFramesInserted, 48_000 * 4)
        let asset = AVURLAsset(url: outputURL)
        let duration = try await asset.load(.duration)
        XCTAssertEqual(duration.seconds, 10.0, accuracy: 0.35)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let audioRange = try await audioTracks[0].load(.timeRange)
        XCTAssertEqual(audioRange.duration.seconds, 10.0, accuracy: 0.35)
    }

    func testExportRefusesExistingOutputWithoutForce() async throws {
        let projectURL = try await makeProject(durationNs: 5_000_000_000)
        let outputURL = directory.appendingPathComponent("exists.mp4")
        try Data("occupied".utf8).write(to: outputURL)

        do {
            _ = try await SegmentAssembler.assemble(projectAt: projectURL, to: outputURL)
            XCTFail("expected EEXIST refusal")
        } catch {
            // Existing file untouched by the failed attempt.
            XCTAssertEqual(try String(contentsOf: outputURL, encoding: .utf8), "occupied")
        }

        // With overwrite the export replaces it.
        let result = try await SegmentAssembler.assemble(
            projectAt: projectURL, to: outputURL, options: .init(overwrite: true))
        XCTAssertGreaterThan(result.videoFrames, 0)
    }

    func testExportRefusesDamagedJournal() async throws {
        let projectURL = try await makeProject(durationNs: 5_000_000_000)
        let journalURL = ProjectLayout(root: projectURL).journalURL
        let handle = try FileHandle(forWritingTo: journalURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("garbage tail".utf8))
        try handle.close()

        do {
            _ = try await SegmentAssembler.assemble(
                projectAt: projectURL,
                to: directory.appendingPathComponent("damaged.mp4"))
            XCTFail("expected refusal on damaged journal")
        } catch let error as ScreenreelError {
            guard case .journalInvalid = error else {
                return XCTFail("expected journalInvalid, got \(error)")
            }
        }
    }

    /// RMS of the first `seconds` of the file's audio track.
    private static func audioRMS(of url: URL, seconds: Double) async throws -> Double {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            return 0
        }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
        ])
        reader.add(output)
        reader.timeRange = CMTimeRange(
            start: .zero, duration: CMTime(seconds: seconds, preferredTimescale: 48_000))
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
        return count > 0 ? (sumSquares / Double(count)).squareRoot() : 0
    }
}
