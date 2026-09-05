import XCTest

@testable import CaptureCore
@testable import ProjectModel

// Device startup is asynchronous: callbacks can arrive before start()
// returns. Waiting to install the consumer until then loses those frames.
private struct DeliveringScreenStartup: ScreenFrameSource {
    let source = SyntheticScreenSource(
        width: 320, height: 180, frameRate: 15, durationNs: 800_000_000, pace: 1)

    func start(_ handler: @escaping @Sendable (VideoFrame) -> Void) async throws {
        try await source.start(handler)
        await source.waitUntilFinished()
    }

    func stop() async { await source.stop() }
}

private struct DeliveringAudioStartup: AudioChunkSource {
    let source = SyntheticAudioSource(
        channels: 1, durationNs: 800_000_000, pace: 1, chunkFrames: 256)

    func start(_ handler: @escaping @Sendable (AudioChunk) -> Void) async throws {
        try await source.start(handler)
        await source.waitUntilFinished()
    }

    func stop() async { await source.stop() }
}

final class SourceStartupTests: XCTestCase {
    func testCallbacksDuringStartupAreDrainedForEveryTrack() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("screenreel-startup-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = CaptureSession(
            projectURL: directory.appendingPathComponent("startup.screenreel"),
            configuration: CaptureConfiguration(
                widthPx: 320, heightPx: 180, nominalFrameRate: 15,
                microphoneEnabled: true, systemAudioEnabled: true, cameraEnabled: true))
        try await session.start(
            screen: DeliveringScreenStartup(), microphone: DeliveringAudioStartup(),
            systemAudio: DeliveringAudioStartup(), camera: DeliveringScreenStartup(),
            cameraSettings: .camera(
                widthPx: 320, heightPx: 180, frameRate: 15,
                segmentDurationNs: 4_000_000_000))
        let result = try await session.stop()
        XCTAssertEqual(result.videoFrames, 12)
        XCTAssertEqual(result.cameraFrames, 12)
        XCTAssertEqual(result.micFrames, 38_400)
        XCTAssertEqual(result.systemAudioFrames, 38_400)
        XCTAssertEqual(result.droppedVideoFrames, 0)
        XCTAssertEqual(result.droppedBuffers, 0)
        XCTAssertTrue(result.validation.isHealthy, "\(result.validation.issues)")
    }
}
