import AVFoundation
import Foundation
import Synchronization
import XCTest

@testable import CaptureCore
@testable import EventCapture
@testable import ExportEngine
@testable import PreviewEngine
@testable import ProjectModel
@testable import TimelineCore

/// Audio offset parity: the exported
/// audio's onset must land exactly where the committed descriptors say the
/// microphone started — through head silence AND through a timeline trim.
/// A drifting onset here is the "voice slides against the video" bug class.
final class AudioOffsetParityTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        super.setUp()
        AtomicFile.fullFsync = false
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("screenreel-offsetparity-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        AtomicFile.fullFsync = true
        super.tearDown()
    }

    // MARK: - Late-start microphone

    /// Synthetic mic that starts delivering `startNs` into the session —
    /// the head-silence case a slow input device produces.
    private final class LateStartAudioSource: AudioChunkSource, @unchecked Sendable {
        private let sampleRate: Double = 48_000
        private let startNs: Int64
        private let durationNs: Int64
        private let pace: Double
        private let chunkFrames = 1024

        private let stopped = Mutex(false)
        private var task: Task<Void, Never>?

        init(startNs: Int64, durationNs: Int64, pace: Double) {
            self.startNs = startNs
            self.durationNs = durationNs
            self.pace = pace
        }

        func start(_ handler: @escaping @Sendable (AudioChunk) -> Void) async throws {
            let sampleRate = self.sampleRate
            let startNs = self.startNs
            let durationNs = self.durationNs
            let pace = self.pace
            let chunkFrames = self.chunkFrames
            task = Task.detached(priority: .userInitiated) { [weak self] in
                var frame = 0
                let wallStart = DispatchTime.now().uptimeNanoseconds
                while true {
                    if Task.isCancelled { return }
                    if let self, self.isStopped() { return }
                    let ptsNs = startNs + Int64(Double(frame) / sampleRate * 1_000_000_000)
                    if ptsNs >= durationNs { return }
                    var samples = [Float](repeating: 0, count: chunkFrames)
                    for index in 0..<chunkFrames {
                        let t = Double(frame + index) / sampleRate
                        samples[index] = Float(sin(2 * .pi * 440 * t)) * 0.5
                    }
                    handler(AudioChunk(
                        samples: samples, frameCount: chunkFrames, channels: 1,
                        sampleRate: sampleRate, ptsNs: ptsNs))
                    frame += chunkFrames
                    if pace > 0 {
                        let targetWall = wallStart
                            + UInt64((Double(startNs) + Double(frame) / sampleRate * 1e9) / pace)
                        let now = DispatchTime.now().uptimeNanoseconds
                        if targetWall > now {
                            try? await Task.sleep(nanoseconds: targetWall - now)
                        }
                    }
                }
            }
        }

        func stop() async {
            stopped.withLock { $0 = true }
            task?.cancel()
            await task?.value
        }

        func waitUntilFinished() async {
            await task?.value
        }

        private func isStopped() -> Bool {
            stopped.withLock { $0 }
        }
    }

    /// Full synthetic session (screen + events for the composition) whose
    /// microphone starts 2 s late.
    private func makeLateMicProject(durationNs: Int64) async throws -> URL {
        let projectURL = directory.appendingPathComponent("p-\(UUID().uuidString).screenreel")
        let configuration = CaptureConfiguration(
            widthPx: 320, heightPx: 180, nominalFrameRate: 30,
            videoCodec: .hevc, displayID: 1,
            microphoneEnabled: true, microphoneDeviceName: "Late Microphone",
            segmentDurationSeconds: 4)
        let session = CaptureSession(projectURL: projectURL, configuration: configuration)
        let screen = SyntheticScreenSource(
            width: 320, height: 180, frameRate: 30, durationNs: durationNs, pace: 4)
        let mic = LateStartAudioSource(
            startNs: 2_000_000_000, durationNs: durationNs, pace: 4)
        try await session.start(screen: screen, microphone: mic, systemAudio: nil)

        let cursorTrackID = try await session.registerEventTrack(type: .cursorEvents)
        let clickTrackID = try await session.registerEventTrack(type: .clickEvents)
        let store = EventChunkStore(
            layout: session.projectLayout(),
            trackIDs: [.cursor: cursorTrackID, .clicks: clickTrackID],
            onCommit: { [session] chunk in
                try await session.commitEventChunk(chunk)
            })
        let (stream, continuation) = AsyncStream.makeStream(of: EventRecord.self)
        let events = SyntheticEventSource(
            durationNs: durationNs, widthPx: 320, heightPx: 180, pace: 4)
        events.start { record in continuation.yield(record) }
        let pump = Task {
            for await record in stream {
                try? await store.append(record)
            }
            try? await store.finish()
        }
        await screen.waitUntilFinished()
        await mic.waitUntilFinished()
        await events.waitUntilFinished()
        continuation.finish()
        await pump.value
        _ = try await session.stop()
        return projectURL
    }

    // MARK: - Decoded onset

    /// Timeline frame (at 48 kHz) of the first decoded sample whose
    /// magnitude clears the threshold; buffer PTS anchors the position so
    /// encoder priming cannot shift the count.
    private func firstLoudFrame(
        of url: URL, threshold: Float = 0.05
    ) async throws -> Int64? {
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
        guard reader.startReading() else { return nil }

        while let sample = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            let pts = CMSampleBufferGetPresentationTimeStamp(sample)
            let baseFrame = Int64((pts.seconds * 48_000).rounded())
            let length = CMBlockBufferGetDataLength(block)
            var bytes = [UInt8](repeating: 0, count: length)
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: &bytes)
            let hit: Int? = bytes.withUnsafeBytes { raw in
                let floats = raw.bindMemory(to: Float.self)
                for (index, value) in floats.enumerated() where abs(value) > threshold {
                    return index
                }
                return nil
            }
            if let hit {
                return baseFrame + Int64(hit)
            }
        }
        return nil
    }

    /// Descriptor truth: where the committed mic track actually starts.
    private func micStartNs(projectURL: URL) throws -> Int64 {
        let loaded = try ProjectPackage.load(at: projectURL)
        let segments = (loaded.manifest.tracks.first { $0.type == .microphone }?.segments ?? [])
            .sorted { $0.sequenceInTrack < $1.sequenceInTrack }
        let start = try XCTUnwrap(segments.first?.normalizedStartNs)
        // The synthetic mic starts exactly 2 s in; the writer must not have
        // shifted its committed start.
        XCTAssertEqual(start, 2_000_000_000)
        return start
    }

    // MARK: - Tests

    func testUntrimmedExportOnsetMatchesDescriptors() async throws {
        let projectURL = try await makeLateMicProject(durationNs: 6_000_000_000)
        let composition = try ProjectComposition(projectURL: projectURL)
        try composition.updateEdits { $0.micNoiseReduction = false }

        let outputURL = directory.appendingPathComponent("untrimmed.mp4")
        _ = try await StyledExporter.export(
            projectAt: projectURL, to: outputURL,
            options: .init(fps: 30, outputHeight: 180))

        let expectedFrame = Int64(
            (Double(try micStartNs(projectURL: projectURL)) / 1e9 * 48_000).rounded())
        let decodedOnset = try await firstLoudFrame(of: outputURL)
        let onset = try XCTUnwrap(decodedOnset, "exported audio is entirely silent")
        XCTAssertLessThanOrEqual(
            abs(onset - expectedFrame), 48,
            "onset frame \(onset) vs descriptor-derived \(expectedFrame)")
    }

    func testTrimmedExportOnsetMatchesDescriptorsMinusTrim() async throws {
        let projectURL = try await makeLateMicProject(durationNs: 6_000_000_000)
        let composition = try ProjectComposition(projectURL: projectURL)
        try composition.updateEdits { edits in
            edits.trimStartNs = 1_000_000_000
            edits.trimEndNs = 5_000_000_000
            edits.micNoiseReduction = false
        }

        let outputURL = directory.appendingPathComponent("trimmed.mp4")
        _ = try await StyledExporter.export(
            projectAt: projectURL, to: outputURL,
            options: .init(fps: 30, outputHeight: 180))

        // Mic at 2 s minus the 1 s trim → onset 1 s into the export.
        let expectedNs = try micStartNs(projectURL: projectURL) - 1_000_000_000
        let expectedFrame = Int64((Double(expectedNs) / 1e9 * 48_000).rounded())
        let decodedOnset = try await firstLoudFrame(of: outputURL)
        let onset = try XCTUnwrap(decodedOnset, "exported audio is entirely silent")
        XCTAssertLessThanOrEqual(
            abs(onset - expectedFrame), 48,
            "onset frame \(onset) vs descriptor-derived \(expectedFrame)")
    }
}
