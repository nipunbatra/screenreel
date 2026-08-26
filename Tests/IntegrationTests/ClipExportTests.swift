import AVFoundation
import Foundation
import ProjectModel
import TimelineCore
import XCTest

@testable import ExportEngine
@testable import PreviewEngine

/// Cuts end-to-end: split + ripple delete must shorten the export exactly,
/// keep audio in lockstep, and preserve preview==export through the shared
/// clip timeline.
final class ClipExportTests: XCTestCase {

    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("aks-clips-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    func testRippleDeleteShortensExportAndKeepsAV() async throws {
        let projectURL = try await SyntheticProjectFactory.make(
            in: directory, durationNs: 9_000_000_000)

        // Cut out the middle third: keep [0,3) and [6,9).
        let composition = try ProjectComposition(projectURL: projectURL)
        try composition.updateEdits { edits in
            edits.clips = [
                Clip(sourceStartNs: 0, sourceEndNs: 3_000_000_000),
                Clip(sourceStartNs: 6_000_000_000, sourceEndNs: 9_000_000_000),
            ]
        }
        XCTAssertEqual(
            Double(composition.outputDurationNs), 6e9, accuracy: 2e6)

        let outputURL = directory.appendingPathComponent("cut.mp4")
        let result = try await StyledExporter.export(
            projectAt: projectURL, to: outputURL,
            options: .init(fps: 30, outputHeight: 180, overwrite: true))
        // Exactly 6 s of output at 30 fps.
        XCTAssertEqual(result.videoFrames, 180)

        let asset = AVURLAsset(url: outputURL)
        let duration = try await asset.load(.duration)
        XCTAssertEqual(duration.seconds, 6.0, accuracy: 0.15)
        if let audio = try await asset.loadTracks(withMediaType: .audio).first {
            let audioRange = try await audio.load(.timeRange)
            XCTAssertEqual(audioRange.duration.seconds, 6.0, accuracy: 0.15)
        }
    }

    func testFrameContentAfterCutComesFromTheKeptSpan() async throws {
        let projectURL = try await SyntheticProjectFactory.make(
            in: directory, durationNs: 9_000_000_000)
        let composition = try ProjectComposition(projectURL: projectURL)
        try composition.updateEdits { edits in
            edits.clips = [
                Clip(sourceStartNs: 0, sourceEndNs: 3_000_000_000),
                Clip(sourceStartNs: 6_000_000_000, sourceEndNs: 9_000_000_000),
            ]
        }
        composition.setOutputSize(SIMD2(320, 180))

        // Output 4 s = source 7 s. The frame there must match the SOURCE
        // frame at 7 s, and differ from the removed source frame at 4 s
        // (the synthetic pattern animates over time).
        let atOutput = try await composition.frame(atOutput: 4_000_000_000)
        let atSourceKept = try await composition.frame(at: 7_000_000_000)
        let atSourceRemoved = try await composition.frame(at: 4_000_000_000)
        let a = try XCTUnwrap(atOutput)
        let b = try XCTUnwrap(atSourceKept)
        let c = try XCTUnwrap(atSourceRemoved)

        let context = CIContext(options: [
            .workingColorSpace: NSNull(), .outputColorSpace: NSNull(),
        ])
        func bytes(_ image: CIImage) -> [UInt8] {
            var pixels = [UInt8](repeating: 0, count: 320 * 180 * 4)
            context.render(
                image, toBitmap: &pixels, rowBytes: 320 * 4,
                bounds: CGRect(x: 0, y: 0, width: 320, height: 180),
                format: .RGBA8, colorSpace: nil)
            return pixels
        }
        let outputBytes = bytes(a)
        XCTAssertEqual(outputBytes, bytes(b), "output frame ≠ kept source frame")
        XCTAssertNotEqual(outputBytes, bytes(c), "output frame equals REMOVED content")
    }

    func testSplitWithoutDeleteChangesNothingVisible() async throws {
        let projectURL = try await SyntheticProjectFactory.make(
            in: directory, durationNs: 6_000_000_000)
        let composition = try ProjectComposition(projectURL: projectURL)
        let before = composition.outputDurationNs
        let timeline = ClipTimeline(
            clips: [], sourceDurationNs: composition.durationNs)
        try composition.updateEdits { edits in
            edits.clips = timeline.splitting(atOutput: 2_000_000_000)
        }
        XCTAssertEqual(composition.outputDurationNs, before)
        XCTAssertEqual(composition.clipTimeline.clips.count, 2)
    }
}

extension ClipExportTests {
    /// A 2× middle clip: export duration shrinks by the sped span's half,
    /// the sped span's audio is silent by policy, normal spans keep audio.
    func testSpedClipExportsShorterWithSilentSpan() async throws {
        let projectURL = try await SyntheticProjectFactory.make(
            in: directory, durationNs: 9_000_000_000)
        let composition = try ProjectComposition(projectURL: projectURL)
        try composition.updateEdits { edits in
            edits.clips = [
                Clip(sourceStartNs: 0, sourceEndNs: 3_000_000_000),
                Clip(sourceStartNs: 3_000_000_000, sourceEndNs: 6_000_000_000, speed: 2),
                Clip(sourceStartNs: 6_000_000_000, sourceEndNs: 9_000_000_000),
            ]
        }
        // 3 + 1.5 + 3 = 7.5 s (±: the source's true duration is a frame
        // tick short of a round number).
        XCTAssertEqual(
            Double(composition.outputDurationNs), 7.5e9, accuracy: 2e6)

        let outputURL = directory.appendingPathComponent("sped.mp4")
        let result = try await StyledExporter.export(
            projectAt: projectURL, to: outputURL,
            options: .init(fps: 30, outputHeight: 180, overwrite: true))
        XCTAssertEqual(result.videoFrames, 225)

        // Decode audio; the sped window (output 3.0–4.5 s) must be silent,
        // its neighbors must not.
        let file = try AVAudioFile(forReading: outputURL)
        let format = file.processingFormat
        func rms(fromSeconds: Double, toSeconds: Double) throws -> Double {
            let start = AVAudioFramePosition(fromSeconds * format.sampleRate)
            let frames = AVAudioFrameCount((toSeconds - fromSeconds) * format.sampleRate)
            file.framePosition = start
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
            try file.read(into: buffer, frameCount: frames)
            guard let data = buffer.floatChannelData?[0] else { return 0 }
            var sum = 0.0
            for index in 0..<Int(buffer.frameLength) {
                sum += Double(data[index]) * Double(data[index])
            }
            return (sum / Double(max(1, buffer.frameLength))).squareRoot()
        }
        let sped = try rms(fromSeconds: 3.2, toSeconds: 4.3)
        let before = try rms(fromSeconds: 1.0, toSeconds: 2.5)
        let after = try rms(fromSeconds: 5.0, toSeconds: 7.0)
        XCTAssertLessThan(sped, 0.003, "sped span must be silent")
        XCTAssertGreaterThan(before, 0.01, "normal span lost its audio")
        XCTAssertGreaterThan(after, 0.01, "post-sped span lost its audio")
    }
}
