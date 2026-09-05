import AVFoundation
import AudioPipeline
import CaptureCore
import ExportEngine
import PreviewEngine
import ProjectModel
import TimelineCore
import XCTest

final class MusicExportTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("screenreel-music-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: directory) }

    private func fixture() async throws -> URL {
        let project = directory.appendingPathComponent("Music.screenreel")
        let session = CaptureSession(projectURL: project, configuration: .init(widthPx: 320, heightPx: 180, microphoneEnabled: false))
        let screen = SyntheticScreenSource(width: 320, height: 180, frameRate: 30, durationNs: 2_000_000_000, pace: 4)
        try await session.start(screen: screen, microphone: nil, systemAudio: nil)
        await screen.waitUntilFinished()
        _ = try await session.stop()
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
        let song = directory.appendingPathComponent("Music.wav")
        do {
            let file = try AVAudioFile(forWriting: song, settings: format.settings)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 22_050)!
            buffer.frameLength = 22_050
            for i in 0..<22_050 {
                buffer.floatChannelData![0][i] = 0.4 * sin(Float(i) * 2 * .pi * 440 / 44_100)
                buffer.floatChannelData![1][i] = 0.2 * sin(Float(i) * 2 * .pi * 660 / 44_100)
            }
            try file.write(from: buffer)
        }
        let composition = try ProjectComposition(projectURL: project)
        var music = try MusicAsset.importFile(song, into: composition.layout)
        music.volume = 0.5
        try composition.updateEdits { $0.music = music }
        return project
    }

    func testMusicOnlyNormalAndCheckpointedExportsHaveMatchingAudibleStereo() async throws {
        let project = try await fixture()
        let composition = try ProjectComposition(projectURL: project)
        let raw = try Data(contentsOf: composition.layout.resolve(relativePath: composition.screenSegments[0].path))
        let normal = directory.appendingPathComponent("normal.mp4")
        let checkpoint = directory.appendingPathComponent("checkpoint.mp4")
        _ = try await StyledExporter.export(projectAt: project, to: normal, options: .init(outputHeight: 180))
        _ = try await CheckpointedExporter.export(projectAt: project, to: checkpoint, options: .init(outputHeight: 180))
        let a = try await decodedAudio(normal), b = try await decodedAudio(checkpoint)
        XCTAssertEqual(a.count, b.count)
        XCTAssertGreaterThan(a.count, 180_000)
        let rmsA = rms(a), rmsB = rms(b)
        XCTAssertGreaterThan(rmsA, 0.08)
        XCTAssertEqual(rmsA, rmsB, accuracy: 0.003)
        XCTAssertGreaterThan(rms(Array(a.suffix(40_000))), 0.08, "short song did not loop to the end")
        XCTAssertEqual(raw, try Data(contentsOf: composition.layout.resolve(relativePath: composition.screenSegments[0].path)))
    }

    func testNoLoopPadsSilenceAndNoAudioOmitsTrack() async throws {
        let project = try await fixture()
        let composition = try ProjectComposition(projectURL: project)
        try composition.updateEdits { $0.music?.loops = false }
        let once = directory.appendingPathComponent("once.mp4")
        _ = try await StyledExporter.export(projectAt: project, to: once, options: .init(outputHeight: 180))
        let audio = try await decodedAudio(once)
        XCTAssertGreaterThan(rms(Array(audio.prefix(24_000))), 0.07)
        XCTAssertLessThan(rms(Array(audio.suffix(48_000))), 0.0001)
        let silent = directory.appendingPathComponent("silent.mp4")
        _ = try await StyledExporter.export(projectAt: project, to: silent, options: .init(outputHeight: 180, includeAudio: false))
        let tracks = try await AVURLAsset(url: silent).loadTracks(withMediaType: .audio)
        XCTAssertTrue(tracks.isEmpty)
    }

    func testTrimAndSpeedChangesKeepContinuousMusic() async throws {
        let project = try await fixture()
        let composition = try ProjectComposition(projectURL: project)
        try composition.updateEdits {
            $0.clips = [Clip(sourceStartNs: 0, sourceEndNs: 1_000_000_000, speed: 2),
                        Clip(sourceStartNs: 1_500_000_000, sourceEndNs: 2_000_000_000)]
            $0.trimStartNs = 200_000_000
            $0.trimEndNs = 900_000_000
        }
        let url = directory.appendingPathComponent("trimmed.mp4")
        let result = try await StyledExporter.export(projectAt: project, to: url, options: .init(outputHeight: 180))
        XCTAssertEqual(result.videoFrames, 21)
        XCTAssertEqual(result.audioFrames, 33_600)
        let audio = try await decodedAudio(url)
        XCTAssertGreaterThan(rms(Array(audio.prefix(24_000))), 0.07, "sped visual span muted music")
        XCTAssertGreaterThan(rms(Array(audio.suffix(24_000))), 0.07)
    }

    func testMissingMusicFailsWithoutDamagingProjectAndSilentExportStillWorks() async throws {
        let project = try await fixture()
        let composition = try ProjectComposition(projectURL: project)
        try composition.updateEdits { $0.music?.path = "assets/music/missing.caf" }
        let output = directory.appendingPathComponent("missing.mp4")
        do {
            _ = try await StyledExporter.export(projectAt: project, to: output, options: .init(outputHeight: 180))
            XCTFail("missing music exported silently")
        } catch { XCTAssertFalse(FileManager.default.fileExists(atPath: output.path)) }
        XCTAssertNoThrow(try ProjectPackage.load(at: project))
        _ = try await StyledExporter.export(projectAt: project, to: output, options: .init(outputHeight: 180, includeAudio: false))
    }

    private func rms(_ samples: [Float]) -> Double {
        (samples.reduce(0.0) { $0 + Double($1 * $1) } / Double(max(1, samples.count))).squareRoot()
    }
    private func decodedAudio(_ url: URL) async throws -> [Float] {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        let track = try XCTUnwrap(tracks.first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false])
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        var samples: [Float] = []
        while let sample = output.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(sample) {
            let count = CMBlockBufferGetDataLength(block) / 4
            var values = [Float](repeating: 0, count: count)
            XCTAssertEqual(CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: count * 4, destination: &values), noErr)
            samples.append(contentsOf: values)
        }
        XCTAssertEqual(reader.status, .completed)
        return samples
    }
}
