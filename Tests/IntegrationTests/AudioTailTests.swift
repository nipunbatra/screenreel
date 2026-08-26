import AVFoundation
import XCTest

@testable import CaptureCore
@testable import ExportEngine
@testable import PreviewEngine
@testable import ProjectModel
@testable import TimelineCore

/// Tail-gap audio shaping: when the
/// microphone dies before the video ends, the styled export still carries a
/// full-length audio track — the missing tail is decoded silence, never a
/// truncated track or a stretched one.
final class AudioTailTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        super.setUp()
        AtomicFile.fullFsync = false
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("aks-audiotail-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        AtomicFile.fullFsync = true
        super.tearDown()
    }

    func testStyledExportPadsTailSilenceToFullVideoDuration() async throws {
        // Mic stops 3 s before the 7 s recording ends.
        let projectURL = try await SyntheticProjectFactory.make(
            in: directory, durationNs: 7_000_000_000,
            micSilenceAfterNs: 4_000_000_000)
        // Denoising off so the silence floor is bit-exact zeros.
        let composition = try ProjectComposition(projectURL: projectURL)
        try composition.updateEdits { $0.micNoiseReduction = false }

        let outputURL = directory.appendingPathComponent("tail.mp4")
        _ = try await StyledExporter.export(
            projectAt: projectURL,
            to: outputURL,
            options: .init(fps: 30, outputHeight: 180))

        let asset = AVURLAsset(url: outputURL)
        let videoRange = try await asset.loadTracks(withMediaType: .video)[0].load(.timeRange)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(audioTracks.count, 1)
        let audioRange = try await audioTracks[0].load(.timeRange)

        // The audio track spans the whole video, not just the recorded mic.
        XCTAssertGreaterThan(videoRange.duration.seconds, 6.5)
        XCTAssertEqual(
            audioRange.duration.seconds, videoRange.duration.seconds, accuracy: 0.12)

        // The padded tail decodes as silence; the recorded range does not.
        let tail = try await audioRMS(of: outputURL, startSeconds: 4.5, durationSeconds: 2.0)
        XCTAssertLessThan(tail, 1e-4, "tail gap is not silent")
        let voiced = try await audioRMS(of: outputURL, startSeconds: 1.0, durationSeconds: 2.0)
        XCTAssertGreaterThan(voiced, 0.05, "recorded microphone range decoded silent")
    }

    /// RMS of `durationSeconds` of the file's audio starting at
    /// `startSeconds` (same probe the export-robustness suite uses).
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
            let length = CMBlockBufferGetDataLength(block)
            var bytes = [UInt8](repeating: 0, count: length)
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: &bytes)
            bytes.withUnsafeBytes { raw in
                for value in raw.bindMemory(to: Float.self) {
                    sumSquares += Double(value) * Double(value)
                    count += 1
                }
            }
        }
        return count > 0 ? (sumSquares / Double(count)).squareRoot() : 0
    }
}
